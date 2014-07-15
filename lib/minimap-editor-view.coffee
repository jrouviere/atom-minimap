{EditorView, ScrollView, $} = require 'atom'
{Emitter} = require 'emissary'
Debug = require 'prolix'
{toArray} = require 'underscore-plus'

WrapperDiv = document.createElement('div')

module.exports =
class MinimapEditorView extends ScrollView
  Emitter.includeInto(this)
  Debug('minimap').includeInto(this)

  @content: ->
    @div class: 'minimap-editor editor editor-colors', =>
      @div class: 'scroll-view', outlet: 'scrollView', =>
        @div class: 'lines', outlet: 'lines'

  frameRequested: false

  constructor: ->
    super
    @pendingChanges = []
    @lineDecorations = {}
    @lineNodesByLineId = {}
    @screenRowsByLineId = {}
    @lineIdsByScreenRow = {}
    @renderedDecorationsByLineId = {}

  initialize: ->
    @lineOverdraw = atom.config.get('minimap.lineOverdraw')

    atom.config.observe 'minimap.lineOverdraw', =>
      @lineOverdraw = atom.config.get('minimap.lineOverdraw')

    atom.config.observe 'editor.lineHeight', =>
      if @editorView?
        @lines.css lineHeight: "#{@getLineHeight()}px"

    atom.config.observe 'editor.fontSize', =>
      if @editorView?
        @lines.css fontSize: "#{@getFontSize()}px"

  destroy: ->
    @unsubscribe()
    @editorView = null

  setEditorView: (@editorView) ->
    @editor = @editorView.getModel()
    @buffer = @editorView.getEditor().buffer

    @lines.css
      lineHeight: "#{@getLineHeight()}px"
      fontSize: "#{@getFontSize()}px"

    @subscribe @editor, 'screen-lines-changed.minimap', (changes) =>
      @pendingChanges.push changes
      @requestUpdate()

  requestUpdate: ->
    return if @frameRequested
    @frameRequested = true

    webkitRequestAnimationFrame =>
      @startBench()
      @update()
      @endBench('minimpap update')
      @frameRequested = false

  scrollTop: (scrollTop, options={}) ->
    return @cachedScrollTop or 0 unless scrollTop?
    return if scrollTop is @cachedScrollTop

    @cachedScrollTop = scrollTop
    @requestUpdate()

  addLineClass: (line, cls) ->
    @lineDecorations[line] ||= []
    @lineDecorations[line].push cls
    @requestUpdate()

  removeLineClass: (line, cls) ->
    if @lineDecorations[line] and (index = @lineDecorations[line].indexOf cls) isnt -1
      @lineDecorations[line].splice(index, 1)
    @requestUpdate()

  removeAllLineClasses: (classesToRemove...) ->
    if classesToRemove.length
      @removeLineClass(cls) for cls in classesToRemove
    else
      @lineDecorations = {}
      @requestUpdate()

  registerBufferChanges: (event) =>
    @pendingChanges.push event

  getMinimapHeight: -> @getLinesCount() * @getLineHeight()
  getLineHeight: -> @lineHeight ||= parseInt @editorView.find('.lines').css('line-height')
  getFontSize: -> @fontSize ||= parseInt @editorView.find('.lines').css('font-size')
  getLinesCount: -> @editorView.getEditor().getScreenLineCount()

  getMinimapScreenHeight: -> @minimapView.height() / @minimapView.scaleY
  getMinimapHeightInLines: -> Math.ceil(@getMinimapScreenHeight() / @getLineHeight())

  getFirstVisibleScreenRow: ->
    screenRow = Math.floor(@scrollTop() / @getLineHeight())
    screenRow = 0 if isNaN(screenRow)
    screenRow

  getLastVisibleScreenRow: ->
    calculatedRow = Math.ceil((@scrollTop() + @getMinimapScreenHeight()) / @getLineHeight()) - 1
    screenRow = Math.max(0, Math.min(@editor.getScreenLineCount() - 1, calculatedRow))
    screenRow = 0 if isNaN(screenRow)
    screenRow

  update: =>
    return unless @editorView?

    firstVisibleScreenRow = @getFirstVisibleScreenRow()
    lastScreenRowToRender = firstVisibleScreenRow + @getMinimapHeightInLines() - 1
    lastScreenRow = @editor.getLastScreenRow()

    if @firstRenderedScreenRow? and firstVisibleScreenRow >= @firstRenderedScreenRow and lastScreenRowToRender <= @lastRenderedScreenRow
      renderFrom = Math.min(lastScreenRow, @firstRenderedScreenRow)
      renderTo = Math.min(lastScreenRow, @lastRenderedScreenRow)
    else
      renderFrom = Math.min(lastScreenRow, Math.max(0, firstVisibleScreenRow - @lineOverdraw))
      renderTo = Math.min(lastScreenRow, lastScreenRowToRender + @lineOverdraw)

    has_no_changes = @pendingChanges.length == 0 and @firstRenderedScreenRow? and @firstRenderedScreenRow <= renderFrom and renderTo <= @lastRenderedScreenRow
    return if has_no_changes

    @clearScreenRowCaches() if @pendingChanges.length
    renderedRowRange = [renderFrom, renderTo]
    @updateLines(renderedRowRange)
    @firstRenderedScreenRow = renderFrom
    @lastRenderedScreenRow = renderTo

    @lines.height(@getMinimapHeight())
    @pendingChanges = []
    @emit 'minimap:updated'

  clearScreenRowCaches: ->
    @screenRowsByLineId = {}
    @lineIdsByScreenRow = {}

  updateLines: (renderedRowRange) ->
    [startRow, endRow] = renderedRowRange

    visibleLines = @editor.linesForScreenRows(startRow, endRow - 1)
    @removeLineNodes(visibleLines)
    @appendOrUpdateVisibleLineNodes(visibleLines, startRow)

  removeLineNodes: (visibleLines=[]) ->
    visibleLineIds = new Set
    visibleLineIds.add(line.id.toString()) for line in visibleLines
    node = @lines[0]

    for lineId, lineNode of @lineNodesByLineId when not visibleLineIds.has(lineId)
      screenRow = @screenRowsByLineId[lineId]
      if not screenRow?
        delete @lineNodesByLineId[lineId]
        delete @lineIdsByScreenRow[screenRow] if @lineIdsByScreenRow[screenRow] is lineId
        delete @screenRowsByLineId[lineId]
        delete @renderedDecorationsByLineId[lineId]
        node.removeChild(lineNode)

  appendOrUpdateVisibleLineNodes: (visibleLines, startRow, updateWidth) ->
    linesComponent = @editorView.component.refs.lines
    linesComponent.props.lineDecorations ||= {}

    newLines = null
    newLinesHTML = null

    for line, index in visibleLines
      screenRow = startRow + index

      if @hasLineNode(line.id)
        @updateLineNode(line, screenRow, updateWidth)
      else
        newLines ?= []
        newLinesHTML ?= ""
        newLines.push(line)
        newLinesHTML += linesComponent.buildLineHTML(line, screenRow)
        @screenRowsByLineId[line.id] = screenRow
        @lineIdsByScreenRow[screenRow] = line.id

      @renderedDecorationsByLineId[line.id] = @lineDecorations[screenRow]

    return unless newLines?

    WrapperDiv.innerHTML = newLinesHTML
    newLineNodes = toArray(WrapperDiv.children)
    node = @lines[0]
    for line, i in newLines
      lineNode = newLineNodes[i]
      classes = @lineDecorations[line.id]
      lineNode.className = 'line'
      lineNode.classList.add(classes...) if classes?
      @lineNodesByLineId[line.id] = lineNode
      node.appendChild(lineNode)

  updateLineNode: (line, screenRow, updateWidth) ->
    lineHeightInPixels = @getLineHeight()

    lineNode = @lineNodesByLineId[line.id]

    decorations = @lineDecorations[screenRow]
    previousDecorations = @renderedDecorationsByLineId[line.id]

    if previousDecorations?
      for decoration in previousDecorations
        unless @hasDecoration(decorations, decoration)
          lineNode.classList.remove(decoration)

    if decorations?
      for decoration in decorations
        unless @hasDecoration(previousDecorations, decoration)
          lineNode.classList.add(decoration)

    unless @screenRowsByLineId[line.id] is screenRow
      lineNode.style.top = screenRow * lineHeightInPixels + 'px'
      lineNode.dataset.screenRow = screenRow
      @screenRowsByLineId[line.id] = screenRow
      @lineIdsByScreenRow[screenRow] = line.id

  hasLineNode: (lineId) ->
    @lineNodesByLineId.hasOwnProperty(lineId)

  hasDecoration: (decorations, decoration) ->
    decorations? and decorations.indexOf(decoration) isnt -1

  getClientRect: ->
    sv = @scrollView[0]
    {
      width: sv.scrollWidth,
      height: sv.scrollHeight
    }
