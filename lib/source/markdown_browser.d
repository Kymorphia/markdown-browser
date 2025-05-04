module markdown_browser;

import gobject.global : signalHandlerBlock, signalHandlerUnblock;
import gdk.types : CURRENT_TIME;
import gtk.box;
import gtk.button;
import gtk.global : showUri;
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
import gtk.types : INVALID_LIST_POSITION, Orientation;
import gtk.widget;
import gtk.window;

import std.algorithm;
import std.file;
import std.path;
import std.range;
import std.regex;

import markdown_view;

class MarkdownBrowser : Box
{
  // Default constants
  enum DefaultHistoryMax = 10;
  enum DefaultFileMatch = r"(.*)\.(md|markdown)$";
  enum DefaultTitleMatch = r"^ {0,3}\# (.*)";
  enum DefaultHomeTopic = "README";
  enum DefaultPanedPosition = 300;

  this()
  {
    super(Orientation.Vertical, 0);

    auto paned = new Paned(Orientation.Horizontal);
    paned.resizeStartChild = false;

    auto box = new Box(Orientation.Vertical, 4);
    box.append(createNavBar);

    auto scrollWin = new ScrolledWindow;
    scrollWin.setChild(createTopicList);
    scrollWin.vexpand = true;
    box.append(scrollWin);

    paned.setStartChild(box);

    _viewScrollWin = new ScrolledWindow;
    _markdownView = new MarkdownView;
    _viewScrollWin.setChild(_markdownView);
    paned.setEndChild(_viewScrollWin);

    paned.vexpand = true;
    paned.position = DefaultPanedPosition;

    append(paned);

    _markdownView.linkClicked.connect(&onLinkClicked);
  }

  private void onLinkClicked(string link) // Called when a link is clicked in the MarkdownView
  {
    if (!link.startsWith("http") && !link.startsWith("mailto")) // Local topic link?
    {
      int topic = getTopicByName(link);
      if (topic != -1)
        navigate(0, topic);
    }
    else // Internet link or email address
      showUri(cast(Window)getAncestor(Window.getType), link, CURRENT_TIME);
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
    _markdownView.render(topicIndex >= 0 ? _topics[topicIndex].content : null);

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

    _homeBtn = Button.newFromIconName("go-home");
    _homeBtn.tooltipText = "Go to documentation home";
    navBar.append(_homeBtn);

    _homeBtn.connectClicked(() {
      if (_homeTopic.length > 0) // Navigate to home topic if it is set
        navigateToTopicByName(_homeTopic);
    });

    auto searchEntry = new SearchEntry;
    searchEntry.tooltipText = "Search help topics";
    searchEntry.hexpand = true;
    navBar.append(searchEntry);

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
  MarkdownView _markdownView; // The markdown view widget
  Button _backBtn; // Back navigation button
  Button _forwardBtn; // Forward navigation button
  Button _homeBtn; // Home button (hidden if there is no home topic)
  Topic[] _topics; // Topics (pages)
  Visit[] _history; // Visit history
  int _historyMax = DefaultHistoryMax; // Maximum history entries
  int _historyPos; // Current history position (can be history.length when at the head of the history)
  string _homeTopic = DefaultHomeTopic; // Home topic
  int _curTopicIndex = TopicNone; // Current topic index
}
