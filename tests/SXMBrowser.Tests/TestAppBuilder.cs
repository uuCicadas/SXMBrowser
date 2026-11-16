using Avalonia;
using Avalonia.Headless;
using SXMBrowser.Desktop;

[assembly: AvaloniaTestApplication(typeof(SXMBrowser.Tests.TestAppBuilder))]

namespace SXMBrowser.Tests;

public sealed class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>()
        .UseSkia()
        .WithInterFont()
        .UseHeadless(new AvaloniaHeadlessPlatformOptions
        {
            UseHeadlessDrawing = false
        });
}
