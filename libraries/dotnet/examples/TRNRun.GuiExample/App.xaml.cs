using System.Windows;
using System.Windows.Threading;

namespace TRNRun.GuiExample;

/// <summary>Starts <see cref="MainWindow"/> with the Fluent theme.</summary>
public partial class App : Application
{
    /// <summary>Shows an unexpected error instead of closing the window, and its runs, with it.</summary>
    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.Message, "TRNRun", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
