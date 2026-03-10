# GTK Markdown Browser
This is a GTK Markdown browser using GtkTextView and GtkTextBuffer. It was created for use as a help system for [Alkimiya](https://www.kymorphia.com/products/alkimiya/) and is being open sourced (under the MIT license) by [Kymorphia, PBC](https://www.kymorphia.com) for use in other applications.

The original intent of this widget was to create a light weight help system based on existing GTK widgets, in contrast to using a full HTML render engine like [WebKitGTK](https://webkitgtk.org/).  A basic limited subset of [Markdown](https://www.markdownguide.org/basic-syntax) is currently supported including:
* Headings (1-6)
* Paragraphs
* Bold and italic emphasis (using \* asterisks only, intentially not using underscore)
* Numbered and un-numbered lists up to 10 levels
* Links (local topics and external links)
* Images with alt text tooltips
* Escape Markdown special characters with backslash

![giD is awesome!](w200:gid-logo.svg)

**Extras**
* GTK icons can be specified as image urls with a "icon:" prefix, such as \[Alt icon text](icon:gtk-home), can also have a size field like \[Large icon](icon:48:gtk-home).

Please see the [Test](test) topic for examples of all currently supported Markdown syntax.

We welcome pull requests for improvements and bug fixes.

Currently there are two Widget derived object types: **MarkdownBrowser**, the main browser widget, and **MarkdownView**, a TextView derived widget used by MarkdownBrowser.

## MarkdownBrowser
This widget is derived from GtkBox and is intended to embed in a GTK Window or Dialog.

A directory of Markdown topics can be added alphabetically with the `addFiles()` method. By default topics are contained in a single Markdown file, with the file name without the .md or .markdown extension used as the topic name ID, and the first Heading1 being used for the title. However topics can also be added with `addTopic()` to define the name, title, and content or to define custom topic sort order.

### Properties

**FIXME:* Many of these aren't currently implemented

* **imagesPath** - Path to base directory for images referenced by markdown content.
* **topicIndex** - Current topic index or -1 if no topic selected.
* **historyPosition** - Current topic history position to store next visit to (can be 1 index after the current history array)
* **historySize** - Current history array size
* **historyMax** - Maximum history size (older entries are removed)
* **bulletChars** - Bullet characters, one for each nested list level, last character is used for remaining levels (default is "●○■")
* **homeTopic** - Home topic name (default is "README")

### Methods
Please consult the MarkdownBrowser.d source for full details.

* `navigate()` - Navigate to a new topic or position in topic visit history.
* `navigateByTopicName()` - Navigate to a topic by name.
* `getTopicByName()` - Get topic index by name.
* `topics` - Get array of browser topic information.
* `history` - Get array of browser visit history information.
* `homeTopic` - Getter and setter for home topic name
* `addTopic()` - Add a single Markdown topic to a browser widget.
* `addFiles()` - Add Markdown files from a directory path.

## MarkdownView

This widget is derived from TextView and provides the basic markdown rendering backend.  It isn't normally used standalone, but is provided if someone wants to create their own browser interface or minimalistic markdown viewer.

It provides one method of interest `render()` for rendering markdown content.  It also has a `Signal!(string) linkClicked` std.signal which can be used for adding a callback which is called when a link is clicked in order to handle the link action.
