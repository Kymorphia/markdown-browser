module markdown_browser;

import gdk.cursor;
import gdk.display;
import gdk.paintable;
import gdk.rectangle;
import gdk.rgba;
import gdk.texture;
import gdk.types : CURRENT_TIME;
import gobject.global : signalHandlerBlock, signalHandlerUnblock;
import gobject.object;
import gtk.box;
import gtk.button;
import gtk.event_controller_motion;
import gtk.gesture_click;
import gtk.global : showUri;
import gtk.icon_theme;
import gtk.label;
import gtk.list_item;
import gtk.list_view;
import gtk.paned;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.signal_list_item_factory;
import gtk.single_selection;
import gtk.string_list;
import gtk.string_object;
import gtk.text_buffer;
import gtk.text_iter;
import gtk.text_mark;
import gtk.text_tag;
import gtk.text_tag_table;
import gtk.text_view;
import gtk.tooltip;
import gtk.types : EventSequenceState, IconLookupFlags, INVALID_LIST_POSITION, Orientation,
  PropagationPhase, TextDirection, TextWindowType, WrapMode;
import gtk.widget;
import gtk.window;
import pango.types : Weight, Style, Underline;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.range;
import std.regex;
import std.string;

class MarkdownBrowser : Box
{
  // Default constants
  enum DefaultHistoryMax = 10;
  enum DefaultFileMatch = r"(.*)\.(md|markdown)$";
  enum DefaultTitleMatch = r"^ {0,3}\# (.*)";
  enum ListLevelCount = 10; // Maximum list levels
  enum HeadersCount = 6; // Maximum header sizes (update headerScales[] if changed)
  enum MaxFirstLevelSpaces = 3;
  enum MaxLevelSpaces = 5;
  enum MinLevelSpacing = 2;
  enum DefaultImagesPath = ".";
  enum DefaultHomeTopic = "README";
  enum DefaultIconSize = 24;
  enum DefaultPanedPosition = 200;

  static immutable DefaultBulletChars = ["●","○","■","▢"]; // Default bullet characters (repeated for additional levels)

  // Update this if HeadersCount is changed
  immutable double[HeadersCount] headerScales = [2.0, 1.75, 1.5, 1.3, 1.2, 1.1];

  this()
  {
    super(Orientation.Vertical, 0);

    append(createNavBar);

    auto paned = new Paned(Orientation.Horizontal);

    auto scrollWin = new ScrolledWindow;
    scrollWin.setChild(createTopicList);
    paned.resizeStartChild = false;
    paned.setStartChild(scrollWin);

    _viewScrollWin = new ScrolledWindow;
    _viewScrollWin.setChild(createTextView);
    paned.setEndChild(_viewScrollWin);

    paned.vexpand = true;
    paned.position = DefaultPanedPosition;

    append(paned);
  }

  /// Get topics
  Topic[] topics()
  {
    return _topics;
  }

  /// Get navigation history
  Visit[] history()
  {
    return _history;
  }

  /// Set home topic name
  @property void homeTopic(string val)
  {
    _homeTopic = val;
    _homeBtn.visible = val.length > 0;
  }

  /// Get home topic name
  @property string homeTopic()
  {
    return _homeTopic;
  }

  /**
   * Navigate to a different page either from history or to a specific topic.
   * Params:
   *   historyOfs = Value to add to the current history position (1: forward, -1: back, 0: don't use history for navigation, etc)
   *   topicIndex = A specific topic to navigate to or TopicNone (default)
   * Returns: true if navigated, false otherwise
   */
  bool navigate(int historyOfs, int topicIndex = TopicNone)
  {
    int newHistoryPos = _historyPos + historyOfs;

    if ((historyOfs != 0 && (newHistoryPos < 0 || newHistoryPos >= _history.length)) ||
        (historyOfs == 0 && ((topicIndex < 0 && topicIndex != TopicNone) || topicIndex >= _topics.length)))
      return false;

    if (_curTopicIndex != TopicNone) // If there is a current topic update history
    {
      auto visit = Visit(_curTopicIndex, _viewScrollWin.vadjustment.value);

      if (_historyPos < _history.length)
      {
        if (historyOfs == 0) // Truncate remaining history if a specific topic is being navigated to
          _history.length = _historyPos + 1;

        _history[_historyPos] = visit;
      }
      else
        _history ~= visit;

      if (_history.length > _historyMax) // Truncate older history if it exceeds max
      {
        _history = _history[_history.length - _historyMax .. $];
        newHistoryPos -= _history.length - _historyMax;

        if (newHistoryPos < 0)
        {
          _historyPos = 0;
          return false;
        }
      }
    }

    if (historyOfs != 0) // Navigating history?
    {
      _historyPos = newHistoryPos;
      topicIndex = _history[_historyPos].topic;
    }
    else // Not navigating history, set position to head of history
      _historyPos = cast(int)_history.length;

    _curTopicIndex = topicIndex;
    renderTopic(topicIndex >= 0 ? &_topics[topicIndex] : null);

    if (historyOfs != 0) // Navigating history? Scroll to the page position
      _viewScrollWin.vadjustment.setValue(_history[_historyPos].scrollValue);

    if (topicIndex >= 0) // If topic is valid, select it
    {
      _topicSelection.signalHandlerBlock(_topicSelectionChangedHandler); // Block selection changed handler so this method doesn't get recursively called
      _topicListView.getModel.selectItem(topicIndex, true); // position, unselectRest
      _topicSelection.signalHandlerUnblock(_topicSelectionChangedHandler);
    }

    _backBtn.sensitive = _historyPos > 0;
    _forwardBtn.sensitive = _historyPos + 1 < _history.length;

    return true;
  }

  /**
   * Navigate to a topic by name.
   * Params:
   *   name = The topic name
   * Returns: true if navigated to the topic, false otherwise
   */
  bool navigateToTopicByName(string name)
  {
    int index = name ? getTopicByName(name) : TopicNone;

    if (index == TopicNone && name)
      return false;

    navigate(0, index);
    return true;
  }

  /**
   * Get index of a topic with a given name.
   * Params:
   *   name = The name of the topic
   * Returns: topic index or TopicNone if not found
   */
  int getTopicByName(string name)
  {
    assert(TopicNone == -1); // countUntil happens to return -1 if not found, which should be TopicNone enum value
    return cast(int)_topics.countUntil!(x => x.name == name);
  }

  /**
   * Add a topic.
   * Params:
   *   name = Topic name
   *   title = Title of the topic
   *   content = The content
   */
  void addTopic(string name, string title, string content)
  { // Insert topic sorted by title
    auto sortedTopics = SortedRange!(Topic[], "a.title < b.title", SortedRangeOptions.assumeSorted)(_topics);
    auto newTopic = Topic(name, title, content);
    auto insertIndex = sortedTopics.lowerBound(newTopic).length;
    _topics.insertInPlace(insertIndex, newTopic);
    _topicModel.splice(cast(uint)insertIndex, 0, [title]); // Insert title in topic model

    if (_curTopicIndex == TopicNone && name == homeTopic)
      navigateToTopicByName(homeTopic);
  }

  /**
   * Parse markdown files into topics.
   * Params:
   *   path = Path to files to load
   *   filePattern = Regular expression pattern for file match
   *   titlePattern = Regular expression pattern for title match
   */
  void addFiles(string path, string filePattern = DefaultFileMatch, string titlePattern = DefaultTitleMatch)
  {
    auto fileRegex = regex(filePattern);
    auto titleRegex = regex(titlePattern, "m");

    foreach (string filename; dirEntries(path, SpanMode.shallow))
    {
      if (auto fileMatch = filename.matchFirst(fileRegex))
      {
        string content = readText(filename);
        string name = fileMatch[1];
        string title;

        if (auto titleMatch = content.matchFirst(titleRegex))
          title = titleMatch[1];

        addTopic(name.baseName.stripExtension, title, content);
      }
    }

    _history.length = 0;
    _historyPos = 0;
    _curTopicIndex = TopicNone;
  }

  // Create navigation bar
  private Widget createNavBar()
  {
    auto navBar = new Box(Orientation.Horizontal, 4);
    navBar.marginStart = 4;
    navBar.marginEnd = 4;
    navBar.marginTop = 4;
    navBar.marginBottom = 4;

    _backBtn = Button.newFromIconName("go-previous");
    _backBtn.sensitive = false;
    _backBtn.tooltipText("Go to previous topic visited");
    _backBtn.connectClicked(() { navigate(-1); }); // Navigate back 1 topic in history
    navBar.append(_backBtn);

    _forwardBtn = Button.newFromIconName("go-next");
    _forwardBtn.sensitive = false;
    _forwardBtn.tooltipText = "Go to next topic visited";
    _forwardBtn.connectClicked(() { navigate(1); }); // Navigate forward 1 topic in history
    navBar.append(_forwardBtn);

    auto searchEntry = new SearchEntry;
    searchEntry.tooltipText = "Search help topics";
    searchEntry.hexpand = true;
    navBar.append(searchEntry);

    _homeBtn = Button.newFromIconName("go-home");
    _homeBtn.tooltipText = "Go to documentation home";
    navBar.append(_homeBtn);

    _homeBtn.connectClicked(() {
      if (_homeTopic.length > 0) // Navigate to home topic if it is set
        navigateToTopicByName(_homeTopic);
    });

    return navBar;
  }

  // Create topic list widgets
  private Widget createTopicList()
  {
    auto scrollWin = new ScrolledWindow;
    scrollWin.marginStart = 4;
    scrollWin.marginEnd = 4;
    scrollWin.marginTop = 4;
    scrollWin.marginBottom = 4;

    _topicModel = new StringList;
    _topicSelection = new SingleSelection(_topicModel);

    _topicSelectionChangedHandler = _topicSelection.connectSelectionChanged(() {
      auto position = _topicSelection.getSelected;

      if (position != INVALID_LIST_POSITION)
        navigate(0, position);
    });

    auto factory = new SignalListItemFactory;

    factory.connectSetup((ListItem listItem) {
      auto label = new Label;
      label.xalign = 0.0;
      listItem.setChild(label);
    });

    factory.connectBind((ListItem listItem) {
      auto label = cast(Label)listItem.getChild;
      auto item = cast(StringObject)listItem.getItem;
      label.setText(item.getString);
    });

    _topicListView = new ListView(_topicSelection, factory);
    scrollWin.setChild(_topicListView);

    return scrollWin;
  }

  // Create text view and buffer
  private Widget createTextView()
  {
    _textView = new TextView;
    _textView.marginStart = 4;
    _textView.marginEnd = 4;
    _textView.marginTop = 4;
    _textView.marginBottom = 4;
    _textView.leftMargin = 4; // Left margin within text view
    _textView.editable = false;
    _textView.cursorVisible = false;
    _textView.wrapMode = WrapMode.WordChar;
    _textBuffer = new TextBuffer(createTagTable);
    _textView.buffer = _textBuffer;

    TextIter iter = new TextIter;
    _textBuffer.getEndIter(iter);
    _appendMark = _textBuffer.createMark("append", iter, true); // Create a mark which is used for tagging appended text (left gravity means inserted text wont move it)

    auto motionController = new EventControllerMotion;
    _textView.addController(motionController);

    motionController.connectMotion((double x, double y) { // Change cursor for links
      int bx, by;
      _textView.windowToBufferCoords(TextWindowType.Text, cast(int)x, cast(int)y, bx, by);

      auto iter = new TextIter;
      auto onLinkNow = _textView.getIterAtLocation(iter, bx, by) && iter.hasTag(_tags[TagEnum.Link]);

      if (onLinkNow != _onLink)
      {
        _textView.setCursor(onLinkNow ? Cursor.newFromName("pointer") : null);
        _onLink = onLinkNow;
      }
    });

    motionController.connectLeave(() { // Set cursor back to default on leave
      if (_onLink)
      {
        _textView.setCursor(null);
        _onLink = false;
      }
    });

    _textView.hasTooltip = true;
    _textView.connectQueryTooltip(&onQueryTooltip);

    auto gestureClick = new GestureClick;
    gestureClick.button = 1; // Left click button only
    gestureClick.propagationPhase = PropagationPhase.Capture; // Run callback in capture phase to be able to stop event propagation for link clicks
    gestureClick.connectPressed(&onButtonPressed);
    _textView.addController(gestureClick);

    return _textView;
  }

  // Create buffer tags table
  private TextTagTable createTagTable()
  {
    _tags ~= new TextTag("B");
    _tags[$ - 1].weight = Weight.Bold;

    _tags ~= new TextTag("I");
    _tags[$ - 1].style = Style.Italic;

    _tags ~= new TextTag("A");
    _tags[$ - 1].foregroundRgba = new RGBA(0.45, 0.62, 0.81, 1.0);
    _tags[$ - 1].underline = Underline.Single;

    foreach (i; 0 .. ListLevelCount)
    {
      _tags ~= new TextTag("L" ~ (i + 1).to!string);
      _tags[$ - 1].pixelsAboveLines = 4;
      _tags[$ - 1].pixelsBelowLines = 4;
      _tags[$ - 1].leftMargin = (i + 1) * 16;
      _tags[$ - 1].indent = -16;
    }

    foreach (i; 0 .. HeadersCount)
    {
      _tags ~= new TextTag("H" ~ (i + 1).to!string);
      _tags[$ - 1].weight = Weight.Bold;
      _tags[$ - 1].scale = headerScales[i];
      _tags[$ - 1].pixelsAboveLines = 8;
      _tags[$ - 1].pixelsBelowLines = 8;
    }

    auto tagTable = new TextTagTable;

    foreach (t; _tags)
      tagTable.add(t);

    return tagTable;
  }

  // Update tooltip when mouse is over links or images with alt tags
  // Should return true if tooltip should be shown now, false otherwise
  private bool onQueryTooltip(int x, int y, bool keyboardMode, Tooltip tooltip)
  {
    int bx, by;
    _textView.windowToBufferCoords(TextWindowType.Text, x, y, bx, by);

    auto iter = new TextIter;
    if (!_textView.getIterAtLocation(iter, bx, by))
      return false;

    if (auto paintable = cast(ObjectWrap)iter.getPaintable)
    {
      if (auto alt = _altLinkMap.get(paintable, null))
      {
        tooltip.setText(alt);
        return true;
      }
    }
    else if (iter.hasTag(_tags[TagEnum.Link]) && (iter.startsTag(_tags[TagEnum.Link])
      || iter.backwardToTagToggle(_tags[TagEnum.Link])))
    {
      foreach (mark; iter.getMarks)
      {
        if (auto link = _altLinkMap.get(mark, null))
        {
          tooltip.setText(link.startsWith("http") || link.startsWith("mailto") ? link : ("Topic: " ~ link));
          return true;
        }
      }
    }

    return false;
  }

  // Mouse button click on TextView
  private void onButtonPressed(int nPress, double x, double y, GestureClick gestureClick)
  {
    int bx, by;
    _textView.windowToBufferCoords(TextWindowType.Text, cast(int)x, cast(int)y, bx, by);

    auto iter = new TextIter;
    if (!_textView.getIterAtLocation(iter, bx, by) || !iter.hasTag(_tags[TagEnum.Link])
        || !(iter.startsTag(_tags[TagEnum.Link]) || iter.backwardToTagToggle(_tags[TagEnum.Link])))
      return;

    foreach (mark; iter.getMarks)
    {
      if (auto link = _altLinkMap.get(mark, null))
      {
        if (!link.startsWith("http") && !link.startsWith("mailto")) // Local topic link?
        {
          int topic = getTopicByName(link);
          if (topic != -1)
            navigate(0, topic);
        }
        else // Internet link or email address
          showUri(cast(Window)getAncestor(Window.getType), link, CURRENT_TIME);

        gestureClick.setState(EventSequenceState.Claimed); // Stop event propagation, otherwise TextView will think user is click-drag selecting text
      }
    }
  }

  // Render a markdown topic to the TextBuffer
  private void renderTopic(Topic* topic)
  {
    auto startIter = new TextIter;
    auto endIter = new TextIter;
    _textBuffer.getBounds(startIter, endIter);
    _textBuffer.delete_(startIter, endIter);
    _altLinkMap.clear; // Clear alt/link text associated with pictures/link marks

    if (!topic) return;

    uint contentPos = 0; // Current markdown content position
    bool bold; // Within a bold emphasis?
    bool italic; // Within an italic emphasis?
    bool link; // Within a link?
    bool listItem; // Within a list item?
    int listLevel; // Current list level
    ubyte[ListLevelCount] listSpacing; // Current list level space indentation
    ubyte[ListLevelCount] numListCounts; // Numeric list counts for each level
    int headerSize; // Current header size (0 if not within a header)

    void bufferAppend(string text) // Append text to TextBuffer with the relevant tags
    {
      text = replaceAll(text, UnescapeRegex, "$1"); // Unescape markdown text

      _textBuffer.getEndIter(endIter);
      _textBuffer.insert(endIter, text); // Append text
      _textBuffer.getEndIter(endIter); // Set endIter to end of buffer
      _textBuffer.getIterAtMark(startIter, _appendMark); // Set startIter to last mark (before insert)
      _textBuffer.moveMark(_appendMark, endIter); // Move the mark to the end of the buffer for next update

      if (bold)
        _textBuffer.applyTag(_tags[TagEnum.Bold], startIter, endIter);

      if (italic)
        _textBuffer.applyTag(_tags[TagEnum.Italic], startIter, endIter);
      
      if (link)
        _textBuffer.applyTag(_tags[TagEnum.Link], startIter, endIter);

      if (listItem)
        _textBuffer.applyTag(_tags[TagEnum.List + listLevel - 1], startIter, endIter);

      if (headerSize > 0)
        _textBuffer.applyTag(_tags[TagEnum.List + ListLevelCount + headerSize - 1], startIter, endIter);
    }

    uint[RegexEnum.max + 1] matchOffsets; // Content offsets from where each regex was performed
    auto matches = iota(cast(uint)RegexEnum.EmphasisEnd).map!(i => topic.content.matchFirst(RegexArray[i])).array; // Array of Captures for each regex (except end regexes)
    matches.length += (RegexEnum.max + 1) - RegexEnum.EmphasisEnd; // Add empty Captures for end regexes, which are updated when corresponding start match is found

    while (true)
    {
      auto nextMatchPos = topic.content.length;
      RegexEnum nextRegexEnum;

      foreach (i; 0 .. RegexEnum.max + 1) // Find the next RegexEnum with the lowest match position
      {
        if (!matches[i].empty && matchOffsets[i] + matches[i].pre.length < nextMatchPos)
        {
          nextRegexEnum = cast(RegexEnum)i;
          nextMatchPos = matchOffsets[i] + matches[i].pre.length;
        }
      }

      // Append content before the next regex match position (if any)
      if (contentPos < nextMatchPos)
        bufferAppend(topic.content[contentPos .. nextMatchPos]);

      if (nextMatchPos == topic.content.length) // No more content to process?
        break;

      if (listLevel > 0 && !listItem && nextRegexEnum != RegexEnum.BulletItemStart // End of list item and not start of a new one? Deactivate list.
          && nextRegexEnum != RegexEnum.NumericItemStart)
        listLevel = 0;

      auto match = matches[nextRegexEnum];

      switch (nextRegexEnum) with (RegexEnum)
      {
        case EmphasisStart:
          italic |= (match.hit.length & 1) != 0; // Italic if 1 or 3 stars
          bold |= (match.hit.length & 2) != 0; // Bold if 2 or 3 stars
          break;
        case HeaderStart:
          headerSize = cast(int)match[1].length;
          break;
        case BulletItemStart:
        case NumericItemStart:
          auto spaceCount = cast(int)match[1].length;

          if (listLevel == 0 && spaceCount > MaxFirstLevelSpaces) // If this is the first level, make sure spaces don't exceed make allowed for a list item
            break;

          listItem = true;
          bool newLevel;

          if (listLevel > 0)
          { // Loop over levels looking for closest spacing match
            uint i;

            for (i = 0; i < listLevel - 1; i++)
              if (spaceCount - listSpacing[i] < listSpacing[i + 1] - spaceCount)
                break;

            newLevel = i == listLevel - 1 && spaceCount >= listSpacing[i] + MinLevelSpacing
              && listLevel < ListLevelCount;

            if (!newLevel)
              listLevel = i + 1;
          }
          else
            newLevel = true;

          if (newLevel)
          {
            listSpacing[listLevel] = cast(ubyte)spaceCount;
            numListCounts[listLevel] = 0;
            listLevel++;
          }

          if (nextRegexEnum == RegexEnum.BulletItemStart)
            bufferAppend(_bulletChars[(listLevel - 1) % _bulletChars.length] ~ " ");
          else
            bufferAppend((++numListCounts[listLevel - 1]).to!string ~ ". ");
          break;
        case Image:
          string imageName = match[2];
          Paintable paintable;

          if (imageName.startsWith("icon:"))
          {
            auto parts = imageName["icon:".length .. $].split(":");
            int size = DefaultIconSize;

            if (parts.length > 1) // Was a size specified?
            {
              try
                size = parts[0].to!int;
              catch (ConvException e)
                {}
            }

            auto iconTheme = IconTheme.getForDisplay(Display.getDefault);
            paintable = iconTheme.lookupIcon(parts[$ - 1], null, size, 96, TextDirection.None, // FIXME - Not sure what to use for scale (96 dpi?)
              IconLookupFlags.ForceSymbolic);
          }
          else
            paintable = Texture.newFromFilename(buildPath(_imagesPath, baseName(imageName)));

          if (paintable)
          {
            string alt = match[1];

            if (alt.length)
              _altLinkMap[cast(ObjectWrap)paintable] = alt;

            _textBuffer.getEndIter(endIter);
            _textBuffer.insertPaintable(endIter, paintable);
          }
          break;
        case Link:
          _textBuffer.getEndIter(endIter);
          auto mark = _textBuffer.createMark(null, endIter, true);
          string linkUrl = match[2];
          _altLinkMap[mark] = linkUrl;
          link = true;
          bufferAppend(match[1]);
          link = false;
          break;
        case EmphasisEnd:
          italic &= (match[1].length & 1) ? false : true; // Count of stars '*'
          bold &= (match[1].length & 2) ? false : true;
          break;
        case HeaderOrListItemEnd:
          headerSize = 0;
          listItem = false;
          break;
        default:
          break;
      }

      contentPos = cast(uint)(matchOffsets[nextRegexEnum] + match.pre.length + match.hit.length); // Advance content position past last match

      matchOffsets[nextRegexEnum] = contentPos;
      matches[nextRegexEnum] = (nextRegexEnum < RegexEnum.EmphasisEnd) ? topic.content[contentPos .. $]
        .matchFirst(RegexArray[nextRegexEnum]) : matches[nextRegexEnum].init;

      if (matches[RegexEnum.EmphasisEnd].empty && (italic || bold)) // Look for end of emphasis?
      {
        matchOffsets[RegexEnum.EmphasisEnd] = contentPos;
        matches[RegexEnum.EmphasisEnd] = topic.content[contentPos .. $].matchFirst(RegexArray[RegexEnum.EmphasisEnd]);
      }

      if (matches[RegexEnum.HeaderOrListItemEnd].empty && (headerSize > 0 || listItem)) // Look for end of header or list item?
      {
        matchOffsets[RegexEnum.HeaderOrListItemEnd] = contentPos;
        matches[RegexEnum.HeaderOrListItemEnd] = topic.content[contentPos .. $]
          .matchFirst(RegexArray[RegexEnum.HeaderOrListItemEnd]);
      }
    }
  }

  /// TextBuffer formatting tag enum
  enum TagEnum
  {
    Bold, /// Bold tag
    Italic, /// Italic tag
    Link, /// Link tag
    List, // A digit starting from 1 is appended for list levels
    Header, // A digit starting from 1 is appended for headers
  }

  /// Token regular expression enum
  enum RegexEnum
  {
    EmphasisStart, /// Emphasis start regex (italic and/or bold)
    HeaderStart, /// Regex to match a header
    BulletItemStart, /// Regex to match a bullet list item
    NumericItemStart, /// Regex to match a numeric list item
    Image, /// An image link
    Link, /// A regular link
    EmphasisEnd, /// Regex to match the end of an emphasis range
    HeaderOrListItemEnd, /// Regex to match the end of a header or list item
  }

  enum UnescapeRegex = ctRegex!(r"\\([\[\]\\`*_{}<>()#+-.!|])", "g"); // Regex to unescape markdown escape sequences

  /// Markdown parser regular expressions
  immutable auto RegexArray = [
    ctRegex!(r"(?<!\\)(\*{1,3})(?![* ])"), // EmphasisStart: Match 1 to 3 asterisks which are not preceded by a backslash and not followed by another asterisk or space
    ctRegex!(r"^ {0,3}(#{1,6}) ", "m"), // HeaderStart: Match 0 to 3 spaces followed by 1 to 6 # characters, followed by a space
    ctRegex!(r"^( *)\* ", "m"), // BulletItemStart: Match 0 or more spaces followed by an asterisk and a space
    ctRegex!(r"^( *)\d+\. ", "m"), // NumericItemStart: Match 0 or more spaces, 1 or more decimal digits, a period and a space
    ctRegex!(r"(?<!\\)!\[([^\]]+)\]\(([^)]+)\)"), // Image: Matches markdown links of the form "![alt text](url)", not preceded by a backslash, and alt text and url do not contain invalid chars
    ctRegex!(r"(?<![!\\])\[([^\]]+)\]\(([^)]+)\)"), // Link: Matches regular markdown links of the form "[text](url)"
    ctRegex!(r"(?<![\\ ])(\*{1,3})"), // EmphasisEnd: Matches 1 to 3 asterisks not preceded by a backslash or a space
    ctRegex!(r"(?=\r\n|[\r\n])"), // HeaderOrListItemEnd: Finds a line break (end of header or list item)
  ];

  /// Browser topic
  struct Topic
  {
    string name; /// Topic name ID
    string title; /// Title
    string content; /// The topic content
  }

  /// Browser visit history information
  struct Visit
  {
    int topic; /// The topic visited
    double scrollValue = 0.0; /// Last scroll Adjustment.value position of the page
  }

  enum TopicNone = -1; /// Used to indicate no topic

private:
  ListView _topicListView; // Topic list view widget
  StringList _topicModel; // Topic list model
  SingleSelection _topicSelection; // Topic selection object
  ulong _topicSelectionChangedHandler; // Topic list selection changed signal handler ID
  ScrolledWindow _viewScrollWin; // Text view scrolled window
  TextView _textView; // Text view widget
  TextBuffer _textBuffer; // Text buffer displayed in the text view
  TextMark _appendMark; // Mark used for tagging appended text (left gravity)
  TextTag[] _tags; // Text format tags
  Button _backBtn; // Back navigation button
  Button _forwardBtn; // Forward navigation button
  Button _homeBtn; // Home button (hidden if there is no home topic)
  Topic[] _topics; // Topics (pages)
  Visit[] _history; // Visit history
  string _imagesPath = DefaultImagesPath; // Path to images
  string[] _bulletChars = DefaultBulletChars; // Bullet characters for each list level (repeated)
  int _historyMax = DefaultHistoryMax; // Maximum history entries
  int _historyPos; // Current history position (can be history.length when at the head of the history)
  string[ObjectWrap] _altLinkMap; // Maps image and mark objects to strings which store "alt" tags or link URLs respectively
  string _homeTopic = DefaultHomeTopic; // Home topic
  int _curTopicIndex = TopicNone; // Current topic index
  bool _onLink; // true if mouse cursor is currently over a link
}
