namespace TRNRun;

/// <summary>TRNSYS window behavior, passed as <c>--guiVisibility</c>.</summary>
public enum GuiVisibility
{
    /// <summary>Stays visible and open after the run.</summary>
    KeepOpen,
    /// <summary>Stays visible and closes after the run.</summary>
    AutoClose,
    /// <summary>Stays minimized and open after the run.</summary>
    Minimized,
    /// <summary>Stays minimized and closes after the run.</summary>
    MinimizedAuto,
    /// <summary>Has no window and closes after the run.</summary>
    Hidden,
}
