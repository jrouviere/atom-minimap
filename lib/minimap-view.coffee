{$, View} = require 'atom'

MinimapEditorView = require './minimap-editor-view'
Debug = require './mixins/debug'

CONFIGS = require './config'

require './resizeend.js'

module.exports =
class MinimapView extends View
  Debug.includeInto(this)

  @content: ->
    @div class: 'minimap', =>
      @div outlet: 'miniWrapper', class: "minimap-wrapper", =>
        @subview 'miniEditorView', new MinimapEditorView()
        @div outlet: 'miniOverlayer', class: "minimap-overlayer"

  configs: {}
  isClicked: false

  # VIEW CREATION/DESTRUCTION

  constructor: (@paneView) ->
    super

    @scaleX = 0.2
    @scaleY = @scaleX * 0.8
    @minimapScale = @scale(@scaleX, @scaleY)
    @miniScrollView = @miniEditorView.scrollView
    @minimapScroll = 0
    @inited = false

  initialize: ->
    @on 'mousewheel', @mouseWheel
    @on 'mousedown', @mouseDown

    @subscribe @paneView.model.$activeItem, @onActiveItemChanged
    @subscribe @miniEditorView, 'minimap:updated', @updateScroll
    @subscribe $(window), 'resize:end', @onScrollViewResized

    themeProp = 'minimap.theme'
    @subscribe atom.config.observe themeProp, callNow: true, =>
      @configs.theme = atom.config.get(themeProp) ? CONFIGS.theme
      @updateTheme()

  destroy: ->
    @off()
    @unsubscribe()

    @deactivatePaneViewMinimap()
    @miniEditorView.destroy()
    @remove()

  # MINIMAP DISPLAY MANAGEMENT

  attachToPaneView: -> @paneView.append(this)
  detachFromPaneView: -> @detach()

  activatePaneViewMinimap: ->
    @paneView.addClass('with-minimap')
    @attachToPaneView()

  deactivatePaneViewMinimap: ->
    @paneView.removeClass('with-minimap')
    @detachFromPaneView()

  resetMinimapTransform: -> @transform @miniWrapper[0], @scale()

  minimapIsAttached: -> @paneView.find('.minimap').length is 1

  # EDITOR VIEW MANAGEMENT

  storeActiveEditor: ->
    @editorView = @getEditorView()

    @unsubscribeFromEditor()

    @editor = @editorView.getEditor()
    @scrollView = @editorView.scrollView
    @scrollViewLines = @scrollView.find('.lines')

    @subscribeToEditor()

  unsubscribeFromEditor: ->
    @unsubscribe @editor, '.minimap'

  subscribeToEditor: ->
    @subscribe @editor, 'screen-lines-changed.minimap', @updateMinimapEditorView
    @subscribe @editor, 'scroll-top-changed.minimap', @updateScroll
    @subscribe @editor, 'scroll-left-changed.minimap', @updateScroll

  getEditorView: -> @paneView.viewForItem(@activeItem)

  getEditorViewClientRect: -> @scrollView[0].getBoundingClientRect()

  getScrollViewClientRect: -> @scrollViewLines[0].getBoundingClientRect()

  setMinimapEditorView: ->
    # update minimap-editor
    setImmediate =>
      @miniEditorView.setEditorView(@editorView)

  # UPDATE METHODS

  # Update Styles
  updateTheme: -> @attr 'data-theme': @configs.theme

  updateMinimapEditorView: => @miniEditorView.update()

  updateMinimapView: ->
    # offset minimap
    @offset top: @editorView.offset().top

    # get rects
    @editorViewRect = @getEditorViewClientRect()
    @scrollViewRect = @getScrollViewClientRect()

    # reset minimap-overlayer
    # top will be set 0 when reseting
    @miniOverlayer.css
      width: @scrollViewRect.width
      height: @editorViewRect.height

    setImmediate => @updateScroll()

  updateScroll: =>
    minimapHeight = @miniScrollView.outerHeight()
    scrollViewHeight = @scrollView.outerHeight()
    scrollViewOffset = @scrollView.offset().top
    overlayerOffset = @scrollView.find('.overlayer').offset().top
    overlayY = -overlayerOffset + scrollViewOffset
    scrollRatio = overlayY / (minimapHeight - scrollViewHeight)
    minimapMaxScroll = ((minimapHeight * @scaleY) - scrollViewHeight) / @scaleY
    minimapCanScroll = (minimapHeight * @scaleY) > scrollViewHeight

    if minimapCanScroll
      @minimapScroll = -(scrollRatio * minimapMaxScroll)
      @transform @miniWrapper[0], @minimapScale + @translateY(@minimapScroll)
    else
      @minimapScroll = 0
      @transform @miniWrapper[0], @minimapScale

    @transform @miniOverlayer[0], @translateY(overlayY)

    unless @inited
      @inited = true
      @css
        '-webkit-transform': 'translate3d(0, 0, 0)',
                  transform: 'translate3d(0, 0, 0)'
      @addClass 'animated fadeIn'
      @one 'webkitAnimationEnd AnimationEnd', =>
        @removeClass 'animated fadeIn'
        @miniWrapper.addClass 'transition'

  # EVENT CALLBACKS

  onActiveItemChanged: (item) =>
    # Fix called twice when opening minimap!
    return if @activeItem == item
    @activeItem = item

    if @activeTabSupportMinimap()
      @log 'minimap is supported by the current tab'
      @activatePaneViewMinimap() unless @minimapIsAttached()
      @storeActiveEditor()
      @setMinimapEditorView()
      @updateMinimapView()
    else
      # Ignore any tab that is not an editor
      @deactivatePaneViewMinimap()
      @log 'minimap is not supported by the current tab'

  mouseWheel: (e) =>
    return if @isClicked
    {wheelDeltaX, wheelDeltaY} = e.originalEvent
    if wheelDeltaX
      @editorView.scrollLeft(@editorView.scrollLeft() - wheelDeltaX)
    if wheelDeltaY
      @editorView.scrollTop(@editorView.scrollTop() - wheelDeltaY)

  mouseDown: (e) =>
    @isClicked = true
    e.preventDefault()
    e.stopPropagation()
    minimapHeight = @miniScrollView.outerHeight()
    miniOverLayerHeight = @miniOverlayer.height()
    # Overlayer's center-y
    y = e.pageY - @offset().top
    y = y - @minimapScroll * @scaleY
    n = y / @scaleY
    top = n - miniOverLayerHeight / 2
    top = Math.max(top, 0)
    top = Math.min(top, minimapHeight - miniOverLayerHeight)
    # @note: currently, no animation.
    @editorView.scrollTop(top)
    # Fix trigger `mousewheel` event.
    setTimeout =>
      @isClicked = false
    , 377

  onScrollViewResized: =>
    @updateMinimapView()

  # OTHER PRIVATE METHODS

  activeTabSupportMinimap: ->
    editorView = @getEditorView()

    editorView? and editorView.hasClass('editor')

  scale: (x=1,y=1) -> "scale(#{x}, #{y}) "
  translateY: (y=0) -> "translate3d(0, #{y}px, 0)"
  transform: (el, transform) ->
    el.style.webkitTransform = el.style.transform = transform
