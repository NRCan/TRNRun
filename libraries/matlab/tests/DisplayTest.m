classdef DisplayTest < matlab.unittest.TestCase
    %DISPLAYTEST Unit tests for trnrun.internal.Display.
    %   Covers throttling, lazy window creation, row caching, line layout,
    %   completion batching, and teardown of interrupted progress.
    %
    %   Live progress goes to a uifigure text area; completed summaries go to
    %   the Command Window. Every test therefore captures console output with
    %   EVALC and reads the live block from the text area.

    properties
        Config
        ExistingFigures
    end

    methods (TestClassSetup)
        function addToolbox(testCase)
            %ADDTOOLBOX Put the toolbox on the path for the whole class.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                toolboxFolder()));
        end
    end

    methods (TestMethodSetup)
        function trackFigures(testCase)
            %TRACKFIGURES Remember pre-existing figures so new ones can be closed.

            testCase.Config = trnrun.SimulationConfig();
            testCase.ExistingFigures = findall(groot, 'Type', 'figure');
        end
    end

    methods (TestMethodTeardown)
        function closeNewFigures(testCase)
            %CLOSENEWFIGURES Leave no progress windows behind.

            created = setdiff(findall(groot, 'Type', 'figure'), ...
                testCase.ExistingFigures);
            delete(created(isgraphics(created)));
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Construction
        % -----------------------------------------------------------------

        function rejectsInvalidRefreshInterval(testCase)
            %REJECTSINVALIDREFRESHINTERVAL The interval is a real, finite scalar.

            finite = 'MATLAB:trnrun:internal:Display:expectedFinite';
            scalar = 'MATLAB:trnrun:internal:Display:expectedScalar';
            type = 'MATLAB:trnrun:internal:Display:invalidType';
            cases = {NaN, finite; Inf, finite; -Inf, finite; ...
                [1 2], scalar; [], scalar; 'a', type; "1", type; {1}, type};
            for index = 1:size(cases, 1)
                testCase.verifyError( ...
                    @() trnrun.internal.Display(cases{index, 1}), ...
                    cases{index, 2}, sprintf('input %d', index));
            end
        end

        function rejectsComplexRefreshIntervals(testCase)
            %REJECTSCOMPLEXREFRESHINTERVALS An interval is a real duration in seconds.

            testCase.verifyError(@() trnrun.internal.Display(1 + 2i), ...
                'MATLAB:trnrun:internal:Display:expectedReal');
        end

        function acceptsIntegerAndRationalIntervals(testCase)
            %ACCEPTSINTEGERANDRATIONALINTERVALS Numeric input is converted to double.

            display = testCase.makeDisplay(int32(2));
            testCase.verifyClass(display, 'trnrun.internal.Display');

            display = testCase.makeDisplay(0.25);
            testCase.verifyClass(display, 'trnrun.internal.Display');
        end

        function disabledDisplayProducesNoOutputOrWindow(testCase)
            %DISABLEDDISPLAYPRODUCESNOOUTPUTORWINDOW A nonpositive interval is headless.

            for interval = [0, -1]
                display = trnrun.internal.Display(interval);
                simulation = testCase.makeSimulation(1);
                output = [ ...
                    capture(@() display.simulationStarted(simulation)), ...
                    capture(@() display.simulationFinished(simulation)), ...
                    capture(@() display.refresh(true)), ...
                    capture(@() delete(display))];

                testCase.verifyEmpty(output, sprintf('interval %g', interval));
                testCase.verifyEmpty(testCase.newFigures(), ...
                    'Disabled displays must not create windows.');
            end
        end

        % -----------------------------------------------------------------
        % Window lifecycle
        % -----------------------------------------------------------------

        function windowIsCreatedLazilyOnTheFirstSimulation(testCase)
            %WINDOWISCREATEDLAZILYONTHEFIRSTSIMULATION Nothing opens until there is work.

            display = testCase.makeDisplay(3600);
            testCase.verifyEmpty(testCase.newFigures());

            capture(@() display.refresh(true));
            testCase.verifyEmpty(testCase.newFigures(), ...
                'An empty refresh has nothing to show.');

            capture(@() display.simulationStarted(testCase.makeSimulation(1)));
            testCase.verifyNumElements(testCase.newFigures(), 1);
        end

        function allSimulationsShareOneWindow(testCase)
            %ALLSIMULATIONSSHAREONEWINDOW The window is reused, never duplicated.

            display = testCase.makeDisplay(3600);
            for index = 1:5
                capture(@() display.simulationStarted(testCase.makeSimulation(index)));
            end

            testCase.verifyNumElements(testCase.newFigures(), 1);
        end

        function textAreaIsReadOnlyAndUnwrapped(testCase)
            %TEXTAREAISREADONLYANDUNWRAPPED Fixed-width columns must not be reflowed.

            display = testCase.makeDisplay(3600);
            capture(@() display.simulationStarted(testCase.makeSimulation(1)));
            area = testCase.textArea();

            testCase.verifyEqual(char(area.Editable), 'off');
            testCase.verifyEqual(char(area.WordWrap), 'off');
            testCase.verifyEqual(area.FontName, get(groot, 'FixedWidthFontName'));
        end

        function closedWindowIsNeverReopened(testCase)
            %CLOSEDWINDOWISNEVERREOPENED Closing the window opts out of live updates.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(simulation));
            window = testCase.newFigures();
            close(window);
            testCase.assertFalse(isgraphics(window));

            capture(@() display.simulationStarted(testCase.makeSimulation(2)));
            capture(@() display.refresh(true));

            testCase.verifyEmpty(testCase.newFigures(), ...
                'A closed window must stay closed.');
        end

        function deleteClosesTheWindow(testCase)
            %DELETECLOSESTHEWINDOW Deleting the display tears down its window.

            display = trnrun.internal.Display(3600);
            capture(@() display.simulationStarted(testCase.makeSimulation(1)));
            window = testCase.newFigures();

            capture(@() delete(display));

            testCase.verifyFalse(isgraphics(window));
        end

        % -----------------------------------------------------------------
        % Throttling
        % -----------------------------------------------------------------

        function firstSimulationForcesARedraw(testCase)
            %FIRSTSIMULATIONFORCESAREDRAW The window must appear without waiting.

            display = testCase.makeDisplay(3600);
            capture(@() display.simulationStarted(testCase.makeSimulation(1)));

            testCase.verifyNumElements(testCase.textArea().Value, 1);
        end

        function laterSimulationsAreThrottled(testCase)
            %LATERSIMULATIONSARETHROTTLED Additional starts wait for the interval.

            display = testCase.makeDisplay(3600);
            capture(@() display.simulationStarted(testCase.makeSimulation(1)));
            capture(@() display.simulationStarted(testCase.makeSimulation(2)));
            capture(@() display.simulationStarted(testCase.makeSimulation(3)));
            area = testCase.textArea();

            testCase.verifyNumElements(area.Value, 1);

            capture(@() display.refresh(true));
            testCase.verifyNumElements(area.Value, 3);
        end

        function refreshHonoursTheInterval(testCase)
            %REFRESHHONOURSTHEINTERVAL An elapsed interval redraws without forcing.

            display = testCase.makeDisplay(1);
            first = testCase.makeSimulation(1);
            second = testCase.makeSimulation(2);
            capture(@() display.simulationStarted(first));
            capture(@() display.simulationStarted(second));
            area = testCase.textArea();
            testCase.assertNumElements(area.Value, 1);

            pause(1.25);
            capture(@() display.refresh());

            testCase.verifyNumElements(area.Value, 2);
        end

        function liveProgressNeverWritesToTheConsole(testCase)
            %LIVEPROGRESSNEVERWRITESTOTHECONSOLE Only completions reach the Command Window.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);

            testCase.verifyEmpty(capture(@() display.simulationStarted(simulation)));
            testCase.verifyEmpty(capture(@() display.refresh(true)));
        end

        function duplicateStartsAreIgnored(testCase)
            %DUPLICATESTARTSAREIGNORED A simulation appears at most once.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(simulation));
            capture(@() display.simulationStarted(simulation));
            capture(@() display.refresh(true));

            testCase.verifyNumElements(testCase.textArea().Value, 1);
        end

        % -----------------------------------------------------------------
        % Line layout
        % -----------------------------------------------------------------

        function rendersEveryFieldOfAProgressingRun(testCase)
            %RENDERSEVERYFIELDOFAPROGRESSINGRUN One line carries the whole run summary.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1, "model.dck");
            simulation.applyEvent(statusEvent("RUNNING"));
            simulation.applyEvent(configEvent(8760));
            simulation.applyEvent(progressEvent(0.5, 1234567, 3661000, 90000000));
            simulation.applyEvent(logEvent("Warning"));
            capture(@() display.simulationStarted(simulation));
            line = testCase.textArea().Value{1};

            testCase.verifyTrue(startsWith(line, '[1] model.dck'));
            testCase.verifySubstring(line, 'Status: RUNNING');
            testCase.verifySubstring(line, 'Logs: N:0 W:1 F:0');
            testCase.verifySubstring(line, 'Elapsed: 01:01:01');
            testCase.verifySubstring(line, 'ETA: 25:00:00');
            testCase.verifySubstring(line, ...
                '[##########----------] 1,234,567 /  8,760 (50%)');
        end

        function rendersPlaceholdersBeforeTheFirstProgress(testCase)
            %RENDERSPLACEHOLDERSBEFORETHEFIRSTPROGRESS A pending row still fills every column.

            display = testCase.makeDisplay(3600);
            capture(@() display.simulationStarted( ...
                testCase.makeSimulation(1, "model.dck")));
            line = testCase.textArea().Value{1};

            testCase.verifySubstring(line, 'Elapsed: --:--:--');
            testCase.verifySubstring(line, 'ETA: --:--:--');
            testCase.verifySubstring(line, '[--------------------] - / -');
            testCase.verifySubstring(line, 'Status:     ');
        end

        function omitsSimulationTimeWithoutAConfigEvent(testCase)
            %OMITSSIMULATIONTIMEWITHOUTACONFIGEVENT The stop time comes only from CONFIG.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            simulation.applyEvent(progressEvent(0.25, 100, 1000, 3000));
            capture(@() display.simulationStarted(simulation));
            line = testCase.textArea().Value{1};

            testCase.verifySubstring(line, '[#####---------------] - / -');
            testCase.verifySubstring(line, '(25%)');
        end

        function truncatesOverlongDeckPathsFromTheLeft(testCase)
            %TRUNCATESOVERLONGDECKPATHSFROMTHELEFT The deck name must stay readable.

            display = testCase.makeDisplay(3600);
            capture(@() display.simulationStarted(testCase.makeSimulation(1, ...
                "C:\a\deeply\nested\output\directory\run_20.dck")));
            line = testCase.textArea().Value{1};

            testCase.verifySubstring(line, '...');
            testCase.verifySubstring(line, 'directory\run_20.dck');
            testCase.verifyFalse(contains(line, 'deeply'));
        end

        function keepsColumnsAlignedAcrossPathLengths(testCase)
            %KEEPSCOLUMNSALIGNEDACROSSPATHLENGTHS Truncation must not shift the columns.

            display = testCase.makeDisplay(3600);
            paths = ["a.dck", "C:\a\deeply\nested\output\dir\run.dck", ...
                "exactly_thirty_two_characters.dk"];
            for index = 1:numel(paths)
                    capture(@() display.simulationStarted( ...
                    testCase.makeSimulation(index + 9, paths(index))));
            end
            capture(@() display.refresh(true));
            lines = cellstr(testCase.textArea().Value);

            firstBar = cellfun(@(row) find(row == '|', 1), lines);
            testCase.verifyNumElements(unique(firstBar), 1);
        end

        function clampsNegativeAndUndefinedTimes(testCase)
            %CLAMPSNEGATIVEANDUNDEFINEDTIMES Missing timing reads as zero, not garbage.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            simulation.applyEvent(progressEvent(0.25, 10, NaN, -1000));
            capture(@() display.simulationStarted(simulation));

            testCase.verifySubstring(testCase.textArea().Value{1}, ...
                'Elapsed: 00:00:00 | ETA: 00:00:00');
        end

        function reportsInfiniteEtaAsInf(testCase)
            %REPORTSINFINITEETAASINF An unbounded estimate is labelled, not clamped.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            simulation.applyEvent(progressEvent(0.1, 10, 0, Inf));
            capture(@() display.simulationStarted(simulation));

            testCase.verifySubstring(testCase.textArea().Value{1}, 'ETA: Inf');
        end

        function doesNotWrapHoursAtTwentyFour(testCase)
            %DOESNOTWRAPHOURSATTWENTYFOUR Long runs report their true elapsed hours.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            simulation.applyEvent(progressEvent(0.5, 10, 360000999, 1000));
            capture(@() display.simulationStarted(simulation));

            testCase.verifySubstring(testCase.textArea().Value{1}, ...
                'Elapsed: 100:00:00 | ETA: 00:00:01');
        end

        function clampsTheProgressBarToItsWidth(testCase)
            %CLAMPSTHEPROGRESSBARTOITSWIDTH Out-of-range fractions stay inside the bar.

            display = testCase.makeDisplay(3600);
            fractions = [-0.5, 0, 1, 2];
            expected = { ...
                '[--------------------]', ...
                '[--------------------]', ...
                '[####################]', ...
                '[####################]'};
            for index = 1:numel(fractions)
                simulation = testCase.makeSimulation(index);
                simulation.applyEvent(progressEvent(fractions(index), 1, 0, 0));
                capture(@() display.simulationStarted(simulation));
                capture(@() display.refresh(true));
                testCase.verifySubstring(testCase.textArea().Value{index}, ...
                    expected{index}, sprintf('fraction %g', fractions(index)));
            end
        end

        function groupsThousandsWithoutTouchingSignsOrNaN(testCase)
            %GROUPSTHOUSANDSWITHOUTTOUCHINGSIGNSORNAN Separators apply to digits only.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            simulation.applyEvent(configEvent(-1234567));
            simulation.applyEvent(progressEvent(0.5, 999.6, 0, 0));
            capture(@() display.simulationStarted(simulation));

            testCase.verifySubstring(testCase.textArea().Value{1}, ...
                ' 1,000 / -1,234,567');
        end

        % -----------------------------------------------------------------
        % Row caching
        % -----------------------------------------------------------------

        function updatingOneRowLeavesTheOthersUnchanged(testCase)
            %UPDATINGONEROWLEAVESTHEOTHERSUNCHANGED Cached rows are reused verbatim.

            display = testCase.makeDisplay(3600);
            simulations = arrayfun(@(index) testCase.makeSimulation(index), 1:3, ...
                'UniformOutput', false);
            for index = 1:3
                capture(@() display.simulationStarted(simulations{index}));
            end
            capture(@() display.refresh(true));
            before = testCase.textArea().Value;

            simulations{2}.applyEvent(progressEvent(0.75, 20, 1000, 1000));
            capture(@() display.refresh(true));
            after = testCase.textArea().Value;

            testCase.verifyEqual(after([1 3]), before([1 3]));
            testCase.verifyNotEqual(after{2}, before{2});
            testCase.verifySubstring(after{2}, '(75%)');
        end

        function cachedRowsTrackLogAndStatusChanges(testCase)
            %CACHEDROWSTRACKLOGANDSTATUSCHANGES The cache key covers every rendered field.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(simulation));

            simulation.applyEvent(statusEvent("RUNNING"));
            capture(@() display.refresh(true));
            testCase.verifySubstring(testCase.textArea().Value{1}, 'Status: RUNNING');

            simulation.applyEvent(logEvent("Fatal"));
            capture(@() display.refresh(true));
            testCase.verifySubstring(testCase.textArea().Value{1}, 'N:0 W:0 F:1');
        end

        function repeatedRefreshesAreIdempotent(testCase)
            %REPEATEDREFRESHESAREIDEMPOTENT Redrawing unchanged state changes nothing.

            display = testCase.makeDisplay(3600);
            capture(@() display.simulationStarted(testCase.makeSimulation(1)));
            before = testCase.textArea().Value;

            testCase.verifyEmpty(capture(@() display.refresh(true)));

            testCase.verifyEqual(testCase.textArea().Value, before);
        end

        % -----------------------------------------------------------------
        % Completion
        % -----------------------------------------------------------------

        function completionsAreBatchedUntilARefresh(testCase)
            %COMPLETIONSAREBATCHEDUNTILAREFRESH Finishing alone prints nothing.

            display = testCase.makeDisplay(3600);
            [first, second] = testCase.makeTwoStarted(display);
            first.applyEvent(statusEvent("DONE"));
            first.markCompleted(completionEvent());

            testCase.verifyEmpty([ ...
                capture(@() display.simulationFinished(first)), ...
                capture(@() display.refresh())]);
            testCase.verifyNumElements(testCase.textArea().Value, 2);

            output = capture(@() display.refresh(true));
            testCase.verifySubstring(output, 'Status: DONE');
            testCase.verifyEqual(sum(output == newline), 1);
            testCase.verifyFalse(contains(output, char(8)), ...
                'Summaries must not rely on backspace erasure.');
            testCase.verifyNumElements(testCase.textArea().Value, 1);
            testCase.verifyTrue(startsWith(testCase.textArea().Value{1}, ...
                sprintf('[%d]', second.id)));
        end

        function theLastCompletionBypassesThrottling(testCase)
            %THELASTCOMPLETIONBYPASSESTHROTTLING An idle display must not hold the summary.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(simulation));
            simulation.applyEvent(statusEvent("ERROR"));
            simulation.markCompleted(completionEvent());

            output = [capture(@() display.simulationFinished(simulation)), ...
                capture(@() display.refresh())];

            testCase.verifySubstring(output, 'Status: ERROR');
        end

        function clearsTheLiveBlockAfterTheLastCompletion(testCase)
            %CLEARSTHELIVEBLOCKAFTERTHELASTCOMPLETION No stale rows outlive the batch.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(simulation));
            simulation.markCompleted(completionEvent());
            capture(@() display.simulationFinished(simulation));
            capture(@() display.refresh());

            testCase.verifyTrue(all(strlength(string(testCase.textArea().Value)) == 0));
        end

        function completedSummariesAreNeverRepeated(testCase)
            %COMPLETEDSUMMARIESARENEVERREPEATED A finished run prints exactly once.

            display = testCase.makeDisplay(3600);
            simulation = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(simulation));
            simulation.markCompleted(completionEvent());
            capture(@() display.simulationFinished(simulation));
            capture(@() display.refresh());

            testCase.verifyEmpty(capture(@() display.refresh(true)));
            testCase.verifyEmpty(capture(@() delete(display)));
        end

        function flushesCompletionsAfterTheWindowIsClosed(testCase)
            %FLUSHESCOMPLETIONSAFTERTHEWINDOWISCLOSED Final output does not need a window.

            display = testCase.makeDisplay(3600);
            [first, second] = testCase.makeTwoStarted(display);
            close(testCase.newFigures());
            for simulation = [first, second]
                simulation.applyEvent(statusEvent("DONE"));
                simulation.markCompleted(completionEvent());
                capture(@() display.simulationFinished(simulation));
            end

            output = capture(@() display.refresh());

            testCase.verifyEqual(count(string(output), 'Status: DONE'), 2);
        end

        function ignoresCompletionOfAnUnstartedSimulation(testCase)
            %IGNORESCOMPLETIONOFANUNSTARTEDSIMULATION Unknown runs have no row to finish.

            display = testCase.makeDisplay(3600);
            started = testCase.makeSimulation(1);
            capture(@() display.simulationStarted(started));
            stranger = testCase.makeSimulation(2);
            stranger.markCompleted(completionEvent());

            testCase.verifyEmpty([ ...
                capture(@() display.simulationFinished(stranger)), ...
                capture(@() display.refresh(true))]);
            testCase.verifyNumElements(testCase.textArea().Value, 1);
        end

        % -----------------------------------------------------------------
        % Teardown
        % -----------------------------------------------------------------

        function deletePrintsInterruptedProgressOnce(testCase)
            %DELETEPRINTSINTERRUPTEDPROGRESSONCE Unfinished rows survive as console text.

            display = trnrun.internal.Display(3600);
            simulation = testCase.makeSimulation(1);
            simulation.applyEvent(statusEvent("RUNNING"));
            capture(@() display.simulationStarted(simulation));

            output = capture(@() delete(display));

            testCase.verifySubstring(output, 'Status: RUNNING');
            testCase.verifyEqual(sum(output == newline), 1);
        end

        function deleteOfAnIdleDisplayIsSilent(testCase)
            %DELETEOFANIDLEDISPLAYISSILENT A display with no work prints nothing.

            display = trnrun.internal.Display(3600);

            testCase.verifyEmpty(capture(@() delete(display)));
        end
    end

    methods (Access = private)
        function display = makeDisplay(testCase, interval)
            %MAKEDISPLAY Create a display that is deleted when the test ends.

            display = trnrun.internal.Display(interval);
            testCase.addTeardown(@() deleteQuietly(display));
        end

        function simulation = makeSimulation(testCase, id, deckPath)
            %MAKESIMULATION Create an accepted simulation with a short deck name.

            if nargin < 3
                deckPath = sprintf('run_%02d.dck', id);
            end
            simulation = trnrun.Simulation(deckPath, testCase.Config, id);
            simulation.markAccepted();
        end

        function [first, second] = makeTwoStarted(testCase, display)
            %MAKETWOSTARTED Add two simulations to the display and flush them.

            first = testCase.makeSimulation(1);
            second = testCase.makeSimulation(2);
            capture(@() display.simulationStarted(first));
            capture(@() display.simulationStarted(second));
            capture(@() display.refresh(true));
        end

        function figures = newFigures(testCase)
            %NEWFIGURES Return figures created since the test started.

            figures = setdiff(findall(groot, 'Type', 'figure'), ...
                testCase.ExistingFigures);
        end

        function area = textArea(testCase)
            %TEXTAREA Return the single live text area of the progress window.

            window = testCase.newFigures();
            testCase.assertNumElements(window, 1, 'Expected one progress window.');
            area = findall(window, 'Type', 'uitextarea');
            testCase.assertNumElements(area, 1, 'Expected one live text area.');
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end

function event = statusEvent(status)
    %STATUSEVENT Build the STATUS fields the display reads.

    event = struct('kind', "STATUS", 'status', string(status));
end

function event = progressEvent(percent, time, elapsed, eta)
    %PROGRESSEVENT Build the PROGRESS fields the display reads, in milliseconds.

    event = struct('kind', "PROGRESS", 'percent', percent, 'time', time, ...
        'elapsed', elapsed, 'eta', eta);
end

function event = configEvent(stop)
    %CONFIGEVENT Build the CONFIG fields the display reads.

    event = struct('kind', "CONFIG", 'stop', stop);
end

function event = logEvent(severity)
    %LOGEVENT Build the LOG fields the severity tallies read.

    event = struct('kind', "LOG", 'severity', string(severity));
end

function event = completionEvent()
    %COMPLETIONEVENT Build a QUEUE/COMPLETED event.

    event = struct('kind', "QUEUE", 'event', "COMPLETED");
end

function output = capture(fcn) %#ok<INUSD>
    %CAPTURE Run FCN and return everything it wrote to the Command Window.
    %   EVALC reads fcn from this workspace, which the Code Analyzer cannot see.

    output = evalc('fcn()');
end

function deleteQuietly(display)
    %DELETEQUIETLY Delete a display without letting its final summary escape.

    if isvalid(display)
        capture(@() delete(display));
    end
end
