"""The errors trnrun raises, so callers can tell them apart without reading messages.

Each also subclasses the built-in error it refines, so ``except RuntimeError``
and ``except ValueError`` keep catching them.
"""


class TrnrunError(Exception):
    """Base class of every error trnrun raises itself."""


class DaemonExitedError(TrnrunError, RuntimeError):
    """trnrund exited on its own, such as after a crash or a startup failure.

    Attributes
    ----------
    exit_code : int or None
        trnrund's exit code, or None if it closed its output without exiting.
    diagnostics : str
        What trnrund wrote to stderr before exiting; empty if nothing.
    """

    def __init__(self, exit_code: int | None, diagnostics: str = "") -> None:
        """Describe the exit from its code and diagnostics."""
        self.exit_code: int | None = exit_code
        self.diagnostics: str = diagnostics
        if exit_code is None:
            message = "trnrund closed its output but did not exit"
        else:
            message = f"trnrund exited with code {exit_code}"
        super().__init__(f"{message}: {diagnostics}" if diagnostics else message)


class RequestRejectedError(TrnrunError, ValueError):
    """trnrund refused a request, such as a run with a missing deck or an unknown run ID."""


class ClosedError(TrnrunError, RuntimeError):
    """The daemon or manager was already closed."""


class ProtocolError(TrnrunError, RuntimeError):
    """trnrund wrote something other than the reply to the request, such as a malformed line."""


class ProtocolVersionError(TrnrunError, ValueError):
    """trnrund speaks a protocol version this package does not."""
