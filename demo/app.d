import std.stdio;

import gio.types : ApplicationFlags;
import gtk.application;
import gtk.application_window;
import gtk.scrolled_window;
import markdown_browser;

class MainWindow : ApplicationWindow
{
  this(gtk.application.Application app, string docsPath = ".")
  {
    super(app);
    setTitle("Main Window");
    setDefaultSize(1200, 800);

    auto mdBrowser = new MarkdownBrowser;
    mdBrowser.addFiles(docsPath);
    setChild(mdBrowser);
  }
}

class MarkdownBrowserApp : Application
{
  MainWindow window;

  this()
  {
    super("com.kymorphia.MarkdownBrowser", ApplicationFlags.DefaultFlags);

    connectActivate(() {
      if (!window)
      {
        window = new MainWindow(this);
        window.present;
      }
    });
  }
}

void main(string[] args)
{
  auto app = new MarkdownBrowserApp;
  app.run(args);
}
