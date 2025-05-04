module markdown_view;

import gdk.cursor;
import gdk.display;
import gdk.paintable;
import gdk.rgba;
import gdk.texture;
import gobject.object;
import gtk.event_controller_motion;
import gtk.gesture_click;
import gtk.icon_theme;
import gtk.text_buffer;
import gtk.text_iter;
import gtk.text_mark;
import gtk.text_tag;
import gtk.text_tag_table;
import gtk.text_view;
import gtk.tooltip;
import gtk.types : EventSequenceState, IconLookupFlags, PropagationPhase, TextDirection, TextWindowType, WrapMode;
import pango.types : Weight, Style, Underline;

import std.algorithm;
import std.array;
import std.conv;
import std.path;
import std.range;
import std.regex;
import std.signals;
import std.string;

class MarkdownView : TextView
{
  // Default constants
  enum ListLevelCount = 10; // Maximum list levels
  enum HeadersCount = 6; // Maximum header sizes (update headerScales[] if changed)
  enum MaxFirstLevelSpaces = 3;
  enum MaxLevelSpaces = 5;
  enum MinLevelSpacing = 2;
  enum DefaultImagesPath = ".";
  enum DefaultHomeTopic = "README";
  enum DefaultIconSize = 24;

  static immutable DefaultBulletChars = ["●","○","■","▢"]; // Default bullet characters (repeated for additional levels)

  // Update this if HeadersCount is changed
  immutable double[HeadersCount] headerScales = [2.0, 1.75, 1.5, 1.3, 1.2, 1.1];

  this()
  {
    marginStart = 4;
    marginEnd = 4;
    marginTop = 4;
    marginBottom = 4;
    leftMargin = 4; // Left margin within text view
    editable = false;
    cursorVisible = false;
    wrapMode = WrapMode.WordChar;

    _textBuffer = new TextBuffer(createTagTable);
    buffer = _textBuffer;

    TextIter iter = new TextIter;
    _textBuffer.getEndIter(iter);
    _appendMark = _textBuffer.createMark("append", iter, true); // Create a mark which is used for tagging appended text (left gravity means inserted text wont move it)

    auto motionController = new EventControllerMotion;
    addController(motionController);

    motionController.connectMotion((double x, double y) { // Change cursor for links
      int bx, by;
      windowToBufferCoords(TextWindowType.Text, cast(int)x, cast(int)y, bx, by);

      auto iter = new TextIter;
      auto onLinkNow = getIterAtLocation(iter, bx, by) && iter.hasTag(_tags[TagEnum.Link]);

      if (onLinkNow != _onLink)
      {
        setCursor(onLinkNow ? Cursor.newFromName("pointer") : null);
        _onLink = onLinkNow;
      }
    });

    motionController.connectLeave(() { // Set cursor back to default on leave
      if (_onLink)
      {
        setCursor(null);
        _onLink = false;
      }
    });

    hasTooltip = true;
    connectQueryTooltip(&onQueryTooltip);

    auto gestureClick = new GestureClick;
    gestureClick.button = 1; // Left click button only
    gestureClick.propagationPhase = PropagationPhase.Capture; // Run callback in capture phase to be able to stop event propagation for link clicks
    gestureClick.connectPressed(&onButtonPressed);
    addController(gestureClick);
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
    windowToBufferCoords(TextWindowType.Text, x, y, bx, by);

    auto iter = new TextIter;
    if (!getIterAtLocation(iter, bx, by))
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
    windowToBufferCoords(TextWindowType.Text, cast(int)x, cast(int)y, bx, by);

    auto iter = new TextIter;
    if (!getIterAtLocation(iter, bx, by) || !iter.hasTag(_tags[TagEnum.Link])
        || !(iter.startsTag(_tags[TagEnum.Link]) || iter.backwardToTagToggle(_tags[TagEnum.Link])))
      return;

    foreach (mark; iter.getMarks)
    {
      if (auto link = _altLinkMap.get(mark, null))
      {
        linkClicked.emit(link);
        gestureClick.setState(EventSequenceState.Claimed); // Stop event propagation, otherwise TextView will think user is click-drag selecting text
      }
    }
  }

  /**
   * Render markdown content. Converts the markdown string content to TextBuffer content with formatting tags.
   * Params:
   *   content = The markdown content to render
   */
  void render(string content)
  {
    auto startIter = new TextIter;
    auto endIter = new TextIter;
    _textBuffer.getBounds(startIter, endIter);
    _textBuffer.delete_(startIter, endIter);
    _altLinkMap.clear; // Clear alt/link text associated with pictures/link marks

    if (content.empty) return;

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
    auto matches = iota(cast(uint)RegexEnum.EmphasisEnd).map!(i => content.matchFirst(RegexArray[i])).array; // Array of Captures for each regex (except end regexes)
    matches.length += (RegexEnum.max + 1) - RegexEnum.EmphasisEnd; // Add empty Captures for end regexes, which are updated when corresponding start match is found

    while (true)
    {
      auto nextMatchPos = content.length;
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
        bufferAppend(content[contentPos .. nextMatchPos]);

      if (nextMatchPos == content.length) // No more content to process?
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
      matches[nextRegexEnum] = (nextRegexEnum < RegexEnum.EmphasisEnd) ? content[contentPos .. $]
        .matchFirst(RegexArray[nextRegexEnum]) : matches[nextRegexEnum].init;

      if (matches[RegexEnum.EmphasisEnd].empty && (italic || bold)) // Look for end of emphasis?
      {
        matchOffsets[RegexEnum.EmphasisEnd] = contentPos;
        matches[RegexEnum.EmphasisEnd] = content[contentPos .. $].matchFirst(RegexArray[RegexEnum.EmphasisEnd]);
      }

      if (matches[RegexEnum.HeaderOrListItemEnd].empty && (headerSize > 0 || listItem)) // Look for end of header or list item?
      {
        matchOffsets[RegexEnum.HeaderOrListItemEnd] = contentPos;
        matches[RegexEnum.HeaderOrListItemEnd] = content[contentPos .. $]
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

  mixin Signal!(string) linkClicked; /// Signal for when a link is clicked

private:
  TextBuffer _textBuffer; // Text buffer displayed in the text view
  TextMark _appendMark; // Mark used for tagging appended text (left gravity)
  TextTag[] _tags; // Text format tags
  string _imagesPath = DefaultImagesPath; // Path to images
  string[] _bulletChars = DefaultBulletChars; // Bullet characters for each list level (repeated)
  string[ObjectWrap] _altLinkMap; // Maps image and mark objects to strings which store "alt" tags or link URLs respectively
  bool _onLink; // true if mouse cursor is currently over a link
}
