class ActivityTicker extends ActivityRightBase

  constructor:(options={}, data)->

    options.cssClass = KD.utils.curry "activity-ticker", options.cssClass

    super options, data

    @filters = null
    @tryCount = 0

    @listController = new KDListViewController
      lazyLoadThreshold: .99
      viewOptions :
        type      : "activities"
        cssClass  : "activities"
        itemClass : ActivityTickerItem

    @showAllLink = new KDCustomHTMLView

    @listView = @listController.getView()

    @listController.on "LazyLoadThresholdReached", @bound "continueLoading"

    @settingsButton = new KDButtonViewWithMenu
      cssClass    : 'ticker-settings-menu'
      title       : ''
      icon        : yes
      iconClass   : "arrow"
      delegate    : @
      menu        : @settingsMenu data
      callback    : (event)=> @settingsButton.contextMenu event

    @itemsIndexed = {}

    group = KD.getSingleton("groupsController")
    group.on "MemberJoinedGroup", @bound "addJoin"
    group.on "LikeIsAdded", @bound "addLike"
    group.on "FollowHappened", @bound "addFollow"
    group.on "PostIsCreated", @bound "addActivity"
    group.on "ReplyIsAdded", @bound "addComment"
    group.on "PostIsDeleted", @bound "deleteActivity"

    @load {}

  settingsMenu:(data)->
    menu =
      'Follower'     :
        callback : =>
          @load filters : ["follower"]
      'Like'   :
        callback : =>
          @load filters : ["like"]
      # Example menu item for multiple filters.
      # 'Follower+Like'   :
      #   callback : =>
      #     @load filters : ["follower", "like"]
      'Member'   :
        callback : =>
          @load filters : ["member"]
      'App'      :
        callback : =>
          @load filters : ["user"]
    return menu

    @listController.listView.on 'ItemWasAdded', (view, index) =>
      if view.getData()?
        itemId = @getItemId view.data
        @itemsIndexed[itemId] = view

  getConstructorName :(obj)->
    if obj and obj.bongo_ and obj.bongo_.constructorName
      return obj.bongo_.constructorName
    return null

  fetchTags:(data, callback)->
    return callback null, null unless data

    if data.tags
      return callback null, data.tags
    else
      data.fetchTags callback

  addActivity: (data)->
    {origin, subject} = data

    unless @filters and "addactivity" in @filters
      return

    unless @getConstructorName(origin) and @getConstructorName(subject)
      return console.warn "data is not valid"

    source = KD.remote.revive subject
    target = KD.remote.revive origin
    as     = "author"

    @fetchTags source, (err, tags)=>
      return log "discarding event, invalid data"  if err or not tags
      source.tags = tags
      @addNewItem {source, target, as}, 0

  deleteActivity: (data) ->
    {origin, subject} = data

    unless @filters and "deleteactivity" in @filters
      return

    unless @getConstructorName(origin) and @getConstructorName(subject)
      return console.warn "data is not valid"

    source = KD.remote.revive subject
    target = KD.remote.revive origin
    as     = "author"

    @removeItem {source, target, as}

  addJoin: (data)->
    {member} = data

    unless @filters and "member" in @filters
      return

    return console.warn "member is not defined in new member event"  unless member

    {constructorName, id} = member
    KD.remote.cacheable constructorName, id, (err, account)=>
      return console.error "account is not found", err if err or not account
      source = KD.getSingleton("groupsController").getCurrentGroup()
      @addNewItem {as: "member", target: account, source  }, 0

  addFollow: (data)->
    {follower, origin} = data

    unless @filters and "follow" in @filters
      return

    return console.warn "data is not valid"  unless follower and origin

    {constructorName, id} = follower
    KD.remote.cacheable constructorName, id, (err, source)=>
      return console.log "account is not found" if err or not source
      {_id:id, bongo_:{constructorName}} = data.origin
      KD.remote.cacheable constructorName, id, (err, target)=>
        return console.log "account is not found" if err or not target
        eventObj = {source:target, target:source, as:"follower"}

        # following tag has its relationship flipped!!!
        if constructorName is "JTag"
          eventObj =
            source : target
            target : source
            as     : "follower"

        @addNewItem eventObj, 0

  addLike: (data)->
    {liker, origin, subject} = data

    unless @filters and "like" in @filters
      return

    unless liker and origin and subject
      return console.warn "data is not valid"

    {constructorName, id} = liker
    KD.remote.cacheable constructorName, id, (err, source)=>
      return console.log "account is not found", err, liker if err or not source

      {_id:id} = origin
      KD.remote.cacheable "JAccount", id, (err, target)=>
        return console.log "account is not found", err, origin if err or not target

        {constructorName, id} = subject
        KD.remote.cacheable constructorName, id, (err, subject)=>
          return console.log "subject is not found", err, data.subject if err or not subject

          eventObj = {source, target, subject, as:"like"}
          @addNewItem eventObj, 0

  addComment: (data) ->
    {origin, reply, subject, replier} = data

    unless @filters and "comment" in @filters
      return

    unless replier and origin and subject and reply
      return console.warn "data is not valid"
    #CtF: such a copy paste it is. could be handled better
    {constructorName, id} = replier
    KD.remote.cacheable constructorName, id, (err, source)=>
      return console.log "account is not found", err, liker if err or not source

      {_id:id} = origin
      KD.remote.cacheable "JAccount", id, (err, target)=>
        return console.log "account is not found", err, origin if err or not target

        {constructorName, id} = subject
        KD.remote.cacheable constructorName, id, (err, subject)=>
          return console.log "subject is not found", err, data.subject if err or not subject

          {constructorName, id} = reply
          KD.remote.cacheable constructorName, id, (err, object)=>
            return console.log "reply is not found", err, data.reply if err or not object

            eventObj = {source, target, subject, object, as:"reply"}
            @addNewItem eventObj, 0

  continueLoading: (loadOptions = {})->
    loadOptions.continue = @filters
    @load loadOptions

  filterItem:(item)->
    {as, source, target} = item
    # objects should be there
    return null  unless source and target and as

    # relationships from guests should not be there
    if source.profile and sourceNickname = source.profile.nickname
      if /^guest-/.test sourceNickname
        return null
    if target.profile and targetNickname = target.profile.nickname
      if /^guest-/.test targetNickname
        return null

    # filter user followed status activity
    if @getConstructorName(source) is "JNewStatusUpdate" and \
        @getConstructorName(target) is "JAccount" and \
        as is "follower"
      return null

    return item

  tryLoadingAgain:(loadOptions={})->
    unless @tryCount?
      return warn "Current try count is not defined, discarding request"

    if @tryCount >= 10
      return warn "Reached max re-tries for What is Happening widget"

    @tryCount++
    return @load loadOptions

  load: (loadOptions = {})->
    if loadOptions.filters
      @filters = loadOptions.filters
      @listController.removeAllItems()

    if loadOptions.continue
      @filters = loadOptions.filters = loadOptions.continue

    lastItem = @listController.getItemsOrdered().last
    lastItemTimestamp = +(new Date())

    if lastItem and timestamp = lastItem.getData().timestamp
      lastItemTimestamp = (new Date(timestamp)).getTime()

    loadOptions.from = lastItemTimestamp

    KD.remote.api.ActivityTicker.fetch loadOptions, (err, items = []) =>
      @listController.hideLazyLoader()
      # if we had any error, try loading again
      if err
        warn err
        return @tryLoadingAgain loadOptions

      for item in items when @filterItem item
        @addNewItem item

      if @listController.getItemCount() < 15
        @tryLoadingAgain loadOptions

  pistachio:
    """
    <div class="activity-ticker right-block-box">
      <h3>What's happening on Koding {{> @settingsButton}}</h3>
      {{> @listView}}
    </div>
    """

  addNewItem: (newItem, index) ->
    itemId = @getItemId newItem

    if not @itemsIndexed[itemId]
      if index? then @listController.addItem newItem, index
      else @listController.addItem newItem
    else
      viewItem = @itemsIndexed[itemId]
      @listController.moveItemToIndex viewItem, 0

  removeItem: (item) ->
    itemId = @getItemId item

    if @itemsIndexed[itemId]
      viewItem = @itemsIndexed[itemId]
      @listController.removeItem viewItem


  getItemId: (item) ->
    {source, target, object, as} = item
    "#{source.getId()}_#{target.getId()}_#{as}_#{object?.getId()}"


