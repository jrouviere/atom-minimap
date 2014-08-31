{EditorView, ScrollView, $} = require 'atom'
{Emitter} = require 'emissary'
Delegato = require 'delegato'
Debug = require 'prolix'

module.exports =
class MinimapEditorView extends ScrollView
  Emitter.includeInto(this)
  Delegato.includeInto(this)
  Debug('minimap').includeInto(this)

  @delegatesProperty 'firstRenderedScreenRow', toMethod: 'getFirstVisibleScreenRow'
  @delegatesProperty 'lastRenderedScreenRow', toMethod: 'getLastVisibleScreenRow'

  @content: ->
    @div class: 'minimap-editor editor editor-colors', =>
      @tag 'canvas', {
        outlet: 'lineCanvas'
        class: 'minimap-canvas'
        id: 'line-canvas'
      }

  frameRequested: false

  constructor: ->
    super
    @pendingChanges = []
    @context = @lineCanvas[0].getContext('2d')
    @tokenColorCache = {}

    @offscreenCanvas = document.createElement('canvas')
    @offscreenCtxt = @offscreenCanvas.getContext('2d')

  initialize: ->
    @lineOverdraw = atom.config.get('minimap.lineOverdraw')
    @lineCanvas.webkitImageSmoothingEnabled = false

    atom.config.observe 'minimap.lineOverdraw', =>
      @lineOverdraw = atom.config.get('minimap.lineOverdraw')

  pixelPositionForScreenPosition: (position) ->
    {row, column} = @buffer.constructor.Point.fromObject(position)
    actualRow = Math.floor(row)

    {top: row * @getLineHeight(), left: column}

  # This prevent plugins that relies on these methods to break
  addLineClass: ->
  removeLineClass: ->
  removeAllLineClasses: ->

  destroy: ->
    @unsubscribe()
    @editorView = null

  setEditorView: (@editorView) ->
    @editor = @editorView.getModel()
    @buffer = @editorView.getEditor().getBuffer()
    @displayBuffer = @editor.displayBuffer

    @subscribe @editor, 'screen-lines-changed.minimap', (changes) =>
      @pendingChanges.push changes
      @requestUpdate()

    @subscribe @editor, 'contents-modified.minimap', =>
      @requestUpdate()

    @subscribe @displayBuffer, 'tokenized.minimap', =>
      @requestUpdate()

  requestUpdate: ->
    return if @frameRequested
    @frameRequested = true

    setImmediate =>
      @startBench()
      @update()
      @endBench('minimap update')
      @frameRequested = false

  forceUpdate: ->
    @tokenColorCache = {}
    @offscreenFirstRow = null
    @offscreenLastRow = null
    @requestUpdate()

  scrollTop: (scrollTop, options={}) ->
    return @cachedScrollTop or 0 unless scrollTop?
    return if scrollTop is @cachedScrollTop

    @cachedScrollTop = scrollTop
    @update()


  getMinimapHeight: -> @getLinesCount() * @getLineHeight()
  getLineHeight: -> 3
  getCharHeight: -> 2
  getCharWidth: -> 1
  getTextOpacity: -> 0.6
  getLinesCount: -> @editorView.getEditor().getScreenLineCount()

  getMinimapScreenHeight: -> @minimapView.height() #/ @minimapView.scaleY
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

  getDefaultColor: ->
    @defaultColor ||= @transparentize(@minimapView.editorView.css('color'), @getTextOpacity())

  retrieveTokenColorFromDom: (token)->
    # This function insert a dummy token element in the DOM compute its style,
    # return its color property, and remove the element from the DOM.
    # This is quite an expensive operation so results are cached in getTokenColor.
    # Note: it's probably not the best way to do that, but that's the simpler approach I found.
    dummyNode = @editorView.find('#minimap-dummy-node')
    if dummyNode[0]?
      root = dummyNode[0]
    else
      root = document.createElement('span')
      root.style.visibility = 'hidden'
      root.id = 'minimap-dummy-node'
      @editorView.append(root)

    parent = root
    for scope in token.scopes
      node = document.createElement('span')
      # css class is the token scope without the dots,
      # see pushScope @ atom/atom/src/lines-component.coffee
      node.className = scope.replace(/\.+/g, ' ')
      if parent
        parent.appendChild(node)
      parent = node

    color = @transparentize(getComputedStyle(parent).getPropertyValue('color'), @getTextOpacity())
    root.innerHTML = ''
    color

  getTokenColor: (token)->
    #Retrieve color from cache if available
    flatScopes = token.scopes.join()
    if flatScopes not of @tokenColorCache
      color = @retrieveTokenColorFromDom(token)
      @tokenColorCache[flatScopes] = color
    @tokenColorCache[flatScopes]

  drawLines: (context, firstRow, lastRow, offsetRow) ->
    lines = @editor.linesForScreenRows(firstRow, lastRow)

    console.log "Drawing from #{firstRow} to #{lastRow} @ #{offsetRow}: #{lines.length} lines"
    lineHeight = @getLineHeight()
    charHeight = @getCharHeight()
    charWidth = @getCharWidth()
    context.lineWidth = charHeight
    displayCodeHighlights = @minimapView.displayCodeHighlights

    for line, row in lines
      x = 0
      y = offsetRow + row
      for token in line.tokens
        w = token.screenDelta
        unless token.isOnlyWhitespace() or token.hasInvisibleCharacters
          context.fillStyle = if displayCodeHighlights
            @getTokenColor(token)
          else
            @getDefaultColor()

          chars = 0
          y0 = y*lineHeight
          for char in token.value
            if /\s/.test char
              if chars > 0
                context.fillRect(x-chars, y0, chars*charWidth, charHeight)
              chars = 0
            else
              chars++

            x += charWidth

          if chars > 0
            context.fillRect(x-chars, y0, chars*charWidth, charHeight)
        else
          x += w * charWidth
    context.fill()

  copyBitmapPart: (context, bitmapCanvas, srcRow, destRow, rowCount) ->
    lineHeight = @getLineHeight()
    context.drawImage(bitmapCanvas,
        0, srcRow * lineHeight,
        bitmapCanvas.width, rowCount * lineHeight,
        0, destRow * lineHeight,
        bitmapCanvas.width, rowCount * lineHeight)
    console.log "Copying from #{srcRow} X #{rowCount} @ #{destRow}"

  update: =>
    return unless @editorView?
    return unless @displayBuffer.tokenizedBuffer.fullyTokenized

    #reset canvas virtual width/height
    @lineCanvas[0].width = @lineCanvas[0].offsetWidth
    @lineCanvas[0].height = @lineCanvas[0].offsetHeight

    lineHeight = @getLineHeight()

    firstRow = @getFirstVisibleScreenRow()
    lastRow = @getLastVisibleScreenRow()

    console.log "firstRow: #{firstRow}, lastRow: #{lastRow}"
    console.log "offscreenFirstRow: #{@offscreenFirstRow}, offscreenLastRow: #{@offscreenLastRow}"

    # TODO: for now we don't handle screen changes, simply ask for a full redraw
    if @offscreenFirstRow? and @pendingChanges.length > 0
      console.log "Changes"
      for change in @pendingChanges
        console.log change
        {start, end, screenDelta} = change

        #reset canvas virtual width/height
        @lineCanvas[0].width = @lineCanvas[0].offsetWidth
        @lineCanvas[0].height = @lineCanvas[0].offsetHeight

        if firstRow < @offscreenFirstRow
          @drawLines(@context, firstRow, @offscreenFirstRow, 0)

        @copyBitmapPart(@context, @offscreenCanvas,
          0,
          @offscreenFirstRow-firstRow,
          start-@offscreenFirstRow)

        middleEnd = end+screenDelta

        if middleEnd >= start
          @drawLines(@context, start, middleEnd, start-firstRow)

        p2From = end-@offscreenFirstRow+1
        p2To = end-firstRow+1+screenDelta

        if p2From < p2To
          @copyBitmapPart(@context, @offscreenCanvas,
            p2From, p2To,
            @offscreenLastRow-p2From)

        if lastRow > @offscreenLastRow-p2From+p2To
          @drawLines(@context, @offscreenLastRow-p2From+p2To, lastRow, @offscreenLastRow-p2From+p2To-firstRow)

        # copy displayed canvas to offscreen canvas
        @offscreenCanvas.width = @lineCanvas[0].width
        @offscreenCanvas.height = @lineCanvas[0].height
        @offscreenCtxt.drawImage(@lineCanvas[0], 0, 0)
        @offscreenFirstRow = firstRow
        @offscreenLastRow = lastRow

      @pendingChanges = []
    else
      console.log "No changes"
      if @offscreenFirstRow?
        @copyBitmapPart(@context, @offscreenCanvas,
          0,
          @offscreenFirstRow-firstRow,
          @offscreenLastRow-@offscreenFirstRow)
        if firstRow < @offscreenFirstRow
          @drawLines(@context, firstRow, @offscreenFirstRow-1, 0)
        if lastRow > @offscreenLastRow
          @drawLines(@context, @offscreenLastRow+1, lastRow, @offscreenLastRow-firstRow)
      else
        @pendingChanges = [] #flush old changes
        @drawLines(@context, firstRow, lastRow, 0)


    # copy displayed canvas to offscreen canvas
    @offscreenCanvas.width = @lineCanvas[0].width
    @offscreenCanvas.height = @lineCanvas[0].height
    @offscreenCtxt.drawImage(@lineCanvas[0], 0, 0)
    @offscreenFirstRow = firstRow
    @offscreenLastRow = lastRow

    @emit 'minimap:updated'

  transparentize: (color, opacity=1) ->
    color.replace('rgb', 'rgba').replace(')', ", #{opacity})")

  getClientRect: ->
    canvas = @lineCanvas[0]
    {
      width: canvas.scrollWidth,
      height: @getMinimapHeight()
    }
