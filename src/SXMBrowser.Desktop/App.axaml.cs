using System.IO;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Views;

namespace SXMBrowser.Desktop;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownMode = ShutdownMode.OnLastWindowClose;
            var model = new AppModel();
            var mainWindow = new MainWindow(model);
            desktop.MainWindow = mainWindow;

            string? startupFolder = ResolveStartupFolder(desktop.Args);
            if (!string.IsNullOrEmpty(startupFolder))
            {
                _ = model.OpenFolderAsync(startupFolder);
            }
        }

        base.OnFrameworkInitializationCompleted();
    }

    private static string? ResolveStartupFolder(string[]? args)
    {
        if (args is null || args.Length == 0) return null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--open" && i + 1 < args.Length && Directory.Exists(args[i + 1]))
            {
                return args[i + 1];
            }
            if (!args[i].StartsWith('-') && Directory.Exists(args[i]))
            {
                return args[i];
            }
        }
        return null;
    }
}
