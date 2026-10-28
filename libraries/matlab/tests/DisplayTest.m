classdef DisplayTest < matlab.unittest.TestCase
    %DISPLAYTEST Unit tests for trnrun.internal.Display.
    %   Covers throttling, lazy window creation, row updates, line layout,
    %   completion batching, and teardown of interrupted progress.
    %
    %   Live progress goes to a uifigure text area; completed summaries go to
    %   the Command Window. Every test therefore captures console output with
    %   EVALC and reads the live block from the text area. Simulations are
    %   parsed from trnrund-shaped records, so no daemon is needed. SHOW
    %   tracks a simulation and refreshes, as the manager does each poll.

    properties
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

            finite = 'MATLAB:validators:mustBeFinite';
            shape = 'MATLAB:validation:IncompatibleSize';
            type = 'MATLAB:validation:UnableToConvert';
            real = 'MATLAB:validators:mustBeReal';
            cases = {NaN, finite; Inf, finite; -Inf, finite; ...
                [1 2], shape; [], shape; {1}, type; 1 + 2i, real};
            for index = 1:size(cases, 1)
                testCase.verifyError( ...
                    @() trnrun.internal.Display(cases{index, 1}), ...
                    cases{index, 2}, sprintf('input %d', index));
            end
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
                simulation = makeSimulation(1);
                output = [ ...
                    show(display, simulation), ...
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

            show(display, makeSimulation(1));
            testCase.verifyNumElements(testCase.newFigures(), 1);
            testCase.verifyNumElements(testCase.textArea().Value, 1, ...
                'The first simulation must be rendered immediately.');
        end

        function textAreaIsReadOnlyAndUnwrapped(testCase)
            %TEXTAREAISREADONLYANDUNWRAPPED Fixed-width columns must not be reflowed.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1));
            area = testCase.textArea();

            testCase.verifyEqual(char(area.Editable), 'off');
            testCase.verifyEqual(char(area.WordWrap), 'off');
            testCase.verifyEqual(area.FontName, get(groot, 'FixedWidthFontName'));
        end

        function closedWindowIsNeverReopened(testCase)
            %CLOSEDWINDOWISNEVERREOPENED Closing the window opts out of live updates.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1));
            window = testCase.newFigures();
            close(window);
            testCase.assertFalse(isgraphics(window));

            show(display, makeSimulation(2));
            capture(@() display.refresh(true));

            testCase.verifyEmpty(testCase.newFigures(), ...
                'A closed window must stay closed.');
        end

        function deleteClosesTheWindow(testCase)
            %DELETECLOSESTHEWINDOW Deleting the display tears down its window.

            display = trnrun.internal.Display(3600);
            show(display, makeSimulation(1));
            window = testCase.newFigures();

            capture(@() delete(display));

            testCase.verifyFalse(isgraphics(window));
        end

        % -----------------------------------------------------------------
        % Throttling
        % -----------------------------------------------------------------

        function laterSimulationsAreThrottled(testCase)
            %LATERSIMULATIONSARETHROTTLED Additional starts wait for the interval.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1));
            show(display, makeSimulation(2));
            show(display, makeSimulation(3));
            area = testCase.textArea();

            testCase.verifyNumElements(area.Value, 1);

            capture(@() display.refresh(true));
            testCase.verifyNumElements(area.Value, 3);
        end

        function refreshHonoursTheInterval(testCase)
            %REFRESHHONOURSTHEINTERVAL An elapsed interval redraws without forcing.

            display = testCase.makeDisplay(1);
            show(display, makeSimulation(1));
            show(display, makeSimulation(2));
            area = testCase.textArea();
            testCase.assertNumElements(area.Value, 1);

            pause(1.25);
            capture(@() display.refresh());

            testCase.verifyNumElements(area.Value, 2);
        end

        function liveProgressNeverWritesToTheConsole(testCase)
            %LIVEPROGRESSNEVERWRITESTOTHECONSOLE Only completions reach the Command Window.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1);

            testCase.verifyEmpty(show(display, simulation));
            testCase.verifyEmpty(capture(@() display.refresh(true)));
        end

        function duplicateTracksAreIgnored(testCase)
            %DUPLICATETRACKSAREIGNORED A simulation appears at most once.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1);
            show(display, simulation);
            show(display, simulation);
            capture(@() display.refresh(true));

            testCase.verifyNumElements(testCase.textArea().Value, 1);
        end

        % -----------------------------------------------------------------
        % Line layout
        % -----------------------------------------------------------------

        function rendersEveryFieldOfAProgressingRun(testCase)
            %RENDERSEVERYFIELDOFAPROGRESSINGRUN One line carries the whole run summary.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1, 'deckFile', 'model.dck', ...
                'trnrunStatus', 'RUNNING', 'stopTime', 8760, 'percent', 0.5, ...
                'simTime', 1234567, 'elapsedMs', 3661000, 'etaMs', 90000000, ...
                'warnings', 1);
            show(display, simulation);
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
            %RENDERSPLACEHOLDERSBEFORETHEFIRSTPROGRESS A run without progress still fills every column.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1));
            line = testCase.textArea().Value{1};

            testCase.verifySubstring(line, 'Elapsed: --:--:--');
            testCase.verifySubstring(line, 'ETA: --:--:--');
            testCase.verifySubstring(line, '[--------------------] - / -');
            testCase.verifySubstring(line, 'Status: RUNNING', ...
                'Without a TRNRun status, the state is shown.');
        end

        function showsTheLabelInsteadOfTheDeckPath(testCase)
            %SHOWSTHELABELINSTEADOFTHEDECKPATH A label names the row.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1, ...
                'label', 'building-a', 'deckFile', 'C:\models\model.dck'));
            line = testCase.textArea().Value{1};

            testCase.verifyTrue(startsWith(line, '[1] building-a'));
            testCase.verifyFalse(contains(line, 'model.dck'));
        end

        function omitsSimulationTimeWithoutAStopTime(testCase)
            %OMITSSIMULATIONTIMEWITHOUTASTOPTIME The stop time comes only from CONFIG.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1, 'percent', 0.25, 'simTime', 100, ...
                'elapsedMs', 1000, 'etaMs', 3000);
            show(display, simulation);
            line = testCase.textArea().Value{1};

            testCase.verifySubstring(line, '[#####---------------] - / -');
            testCase.verifySubstring(line, '(25%)');
        end

        function truncatesOverlongDeckPathsFromTheLeft(testCase)
            %TRUNCATESOVERLONGDECKPATHSFROMTHELEFT The deck name must stay readable.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1, 'deckFile', ...
                'C:\a\deeply\nested\output\directory\run_20.dck'));
            line = testCase.textArea().Value{1};

            testCase.verifySubstring(line, '...');
            testCase.verifySubstring(line, 'directory\run_20.dck');
            testCase.verifyFalse(contains(line, 'deeply'));
        end

        function keepsColumnsAlignedAcrossPathLengths(testCase)
            %KEEPSCOLUMNSALIGNEDACROSSPATHLENGTHS Truncation must not shift the columns.

            display = testCase.makeDisplay(3600);
            paths = {'a.dck', 'C:\a\deeply\nested\output\dir\run.dck', ...
                'exactly_thirty_two_characters.dk'};
            for index = 1:numel(paths)
                show(display, makeSimulation(index + 9, 'deckFile', paths{index}));
            end
            capture(@() display.refresh(true));
            lines = cellstr(testCase.textArea().Value);

            firstBar = cellfun(@(row) find(row == '|', 1), lines);
            testCase.verifyNumElements(unique(firstBar), 1);
        end

        function clampsNegativeAndUndefinedTimes(testCase)
            %CLAMPSNEGATIVEANDUNDEFINEDTIMES Missing timing reads as zero, not garbage.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1, 'percent', 0.25, 'simTime', 10, ...
                'elapsedMs', [], 'etaMs', -1000);
            show(display, simulation);

            testCase.verifySubstring(testCase.textArea().Value{1}, ...
                'Elapsed: 00:00:00 | ETA: 00:00:00');
        end

        function reportsInfiniteEtaAsInf(testCase)
            %REPORTSINFINITEETAASINF An unbounded estimate is labelled, not clamped.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1, 'percent', 0.1, 'simTime', 10, ...
                'elapsedMs', 0, 'etaMs', Inf);
            show(display, simulation);

            testCase.verifySubstring(testCase.textArea().Value{1}, 'ETA: Inf');
        end

        function doesNotWrapHoursAtTwentyFour(testCase)
            %DOESNOTWRAPHOURSATTWENTYFOUR Long runs report their true elapsed hours.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1, 'percent', 0.5, 'simTime', 10, ...
                'elapsedMs', 360000999, 'etaMs', 1000);
            show(display, simulation);

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
                simulation = makeSimulation(index, 'percent', fractions(index), ...
                    'simTime', 1, 'elapsedMs', 0, 'etaMs', 0);
                show(display, simulation);
                capture(@() display.refresh(true));
                testCase.verifySubstring(testCase.textArea().Value{index}, ...
                    expected{index}, sprintf('fraction %g', fractions(index)));
            end
        end

        function groupsThousandsWithoutTouchingSignsOrNaN(testCase)
            %GROUPSTHOUSANDSWITHOUTTOUCHINGSIGNSORNAN Separators apply to digits only.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1, 'stopTime', -1234567, ...
                'percent', 0.5, 'simTime', 999.6, 'elapsedMs', 0, 'etaMs', 0);
            show(display, simulation);

            testCase.verifySubstring(testCase.textArea().Value{1}, ...
                ' 1,000 / -1,234,567');
        end

        % -----------------------------------------------------------------
        % Row updates
        % -----------------------------------------------------------------

        function updatingOneRowLeavesTheOthersUnchanged(testCase)
            %UPDATINGONEROWLEAVESTHEOTHERSUNCHANGED Unchanged simulations keep their rows verbatim.

            display = testCase.makeDisplay(3600);
            simulations = trnrun.Simulation.empty(1, 0);
            for index = 1:3
                simulations(index) = makeSimulation(index);
                show(display, simulations(index));
            end
            capture(@() display.refresh(true));
            before = testCase.textArea().Value;

            testCase.report(simulations(2), 'percent', 0.75, 'simTime', 20, ...
                'elapsedMs', 1000, 'etaMs', 1000);
            capture(@() display.refresh(true));
            after = testCase.textArea().Value;

            testCase.verifyEqual(after([1 3]), before([1 3]));
            testCase.verifyNotEqual(after{2}, before{2});
            testCase.verifySubstring(after{2}, '(75%)');
        end

        function rowsTrackLogAndStatusChanges(testCase)
            %ROWSTRACKLOGANDSTATUSCHANGES Each redraw renders the latest report.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1);
            show(display, simulation);

            testCase.report(simulation, 'trnrunStatus', 'LAUNCHING');
            capture(@() display.refresh(true));
            testCase.verifySubstring(testCase.textArea().Value{1}, 'Status: LAUNCHING');

            testCase.report(simulation, 'trnrunStatus', 'LAUNCHING', 'fatals', 1);
            capture(@() display.refresh(true));
            testCase.verifySubstring(testCase.textArea().Value{1}, 'N:0 W:0 F:1');
        end

        % -----------------------------------------------------------------
        % Completion
        % -----------------------------------------------------------------

        function completionsAreBatchedUntilARefresh(testCase)
            %COMPLETIONSAREBATCHEDUNTILAREFRESH Finishing alone prints nothing.

            display = testCase.makeDisplay(3600);
            [first, second] = testCase.makeTwoTracked(display);
            testCase.finish(first, 'DONE');

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
                sprintf('[%d]', second.simId)));
        end

        function theLastCompletionBypassesThrottling(testCase)
            %THELASTCOMPLETIONBYPASSESTHROTTLING An idle display must not hold the summary.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1);
            show(display, simulation);
            testCase.finish(simulation, 'ERROR');

            output = [capture(@() display.simulationFinished(simulation)), ...
                capture(@() display.refresh())];

            testCase.verifySubstring(output, 'Status: ERROR');
        end

        function clearsTheLiveBlockAfterTheLastCompletion(testCase)
            %CLEARSTHELIVEBLOCKAFTERTHELASTCOMPLETION No stale rows outlive the batch.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1);
            show(display, simulation);
            testCase.finish(simulation, 'DONE');
            capture(@() display.simulationFinished(simulation));
            capture(@() display.refresh());

            testCase.verifyTrue(all(strlength(string(testCase.textArea().Value)) == 0));
        end

        function completedSummariesAreNeverRepeated(testCase)
            %COMPLETEDSUMMARIESARENEVERREPEATED A finished run prints exactly once.

            display = testCase.makeDisplay(3600);
            simulation = makeSimulation(1);
            show(display, simulation);
            testCase.finish(simulation, 'DONE');
            capture(@() display.simulationFinished(simulation));
            capture(@() display.refresh());

            testCase.verifyEmpty(capture(@() display.refresh(true)));
            testCase.verifyEmpty(capture(@() delete(display)));
        end

        function flushesCompletionsAfterTheWindowIsClosed(testCase)
            %FLUSHESCOMPLETIONSAFTERTHEWINDOWISCLOSED Final output does not need a window.

            display = testCase.makeDisplay(3600);
            [first, second] = testCase.makeTwoTracked(display);
            close(testCase.newFigures());
            for simulation = [first, second]
                testCase.finish(simulation, 'DONE');
                capture(@() display.simulationFinished(simulation));
            end

            output = capture(@() display.refresh());

            testCase.verifyEqual(count(string(output), 'Status: DONE'), 2);
        end

        function ignoresCompletionOfAnUntrackedSimulation(testCase)
            %IGNORESCOMPLETIONOFANUNTRACKEDSIMULATION Unknown runs have no row to finish.

            display = testCase.makeDisplay(3600);
            show(display, makeSimulation(1));
            stranger = makeSimulation(2, 'state', 'FINISHED');

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
            show(display, makeSimulation(1, 'trnrunStatus', 'RUNNING'));

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

        function report(~, simulation, varargin)
            %REPORT Update SIMULATION in place from makeSimulation defaults plus overrides.

            simulation.update(makeSimulation(simulation.simId, ...
                'deckFile', simulation.deckFile, varargin{:}));
        end

        function finish(testCase, simulation, status)
            %FINISH Report SIMULATION finished with TRNRun status STATUS.

            testCase.report(simulation, 'state', 'FINISHED', 'trnrunStatus', status);
        end

        function [first, second] = makeTwoTracked(~, display)
            %MAKETWOTRACKED Add two simulations to the display and flush them.

            first = makeSimulation(1);
            second = makeSimulation(2);
            show(display, first);
            show(display, second);
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

function simulation = makeSimulation(id, varargin)
    %MAKESIMULATION Parse a RUNNING trnrund record; name-value pairs override fields, [] is null.

    record = struct('simId', id, 'label', [], 'state', 'RUNNING', ...
        'deckFile', sprintf('run_%02d.dck', id), 'trnrunOptions', struct(), ...
        'trnrunStatus', [], 'trnrunMessage', [], 'percent', [], ...
        'simTime', [], 'elapsedMs', [], 'etaMs', [], 'startTime', [], ...
        'stopTime', [], 'timeStep', [], 'setting', [], ...
        'notices', 0, 'warnings', 0, 'fatals', 0, 'succeeded', [], ...
        'exitCode', [], 'error', [], 'submittedAt', [], 'startedAt', [], ...
        'finishedAt', []);
    for index = 1:2:numel(varargin)
        record.(varargin{index}) = varargin{index + 1};
    end
    simulation = trnrun.Simulation(record);
end

function output = show(display, simulation) %#ok<INUSD>
    %SHOW Track SIMULATION and refresh, as the manager does each poll.

    output = evalc('display.track(simulation); display.refresh();');
end

function output = capture(fcn) %#ok<INUSD>
    %CAPTURE Run FCN and return everything it wrote to the Command Window.

    output = evalc('fcn()');
end

function deleteQuietly(display)
    %DELETEQUIETLY Delete a display without letting its final summary escape.

    if isvalid(display)
        capture(@() delete(display));
    end
end
