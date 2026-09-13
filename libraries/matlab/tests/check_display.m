function check_display()
%CHECK_DISPLAY Exercise the native progress window without running simulations.
% Add libraries/matlab/toolbox and this directory to the MATLAB path first.

    before = findall(groot, 'Type', 'figure');
    display = trnrun.internal.Display(3600);
    cleanup = onCleanup(@() delete(display)); %#ok<NASGU>
    assert(isequal(findall(groot, 'Type', 'figure'), before), 'Create the window lazily.');
    sims = cell(1, 20);
    for index = 1:20
        name = sprintf('run_%02d.dck', index);
        if index == 20
            % Overflows the path column, so alignment must survive truncation.
            name = ['C:\a\deeply\nested\output\directory\' name];
        end
        sims{index} = trnrun.Simulation(name, trnrun.SimulationConfig(), index);
        sims{index}.applyEvent(struct('kind', 'STATUS', 'status', 'RUNNING'));
        output = evalc('display.simulationStarted(sims{index});');
        assert(isempty(output), 'Live progress must not write to the console.');
    end
    sims{1}.applyEvent(struct('kind', 'CONFIG', 'stop', 8760));
    sims{1}.applyEvent(struct('kind', 'PROGRESS', 'percent', 0.5, ...
        'time', 1234567, 'elapsed', 3661000, 'eta', 90000000));
    window = setdiff(findall(groot, 'Type', 'figure'), before);
    assert(isscalar(window), 'Use one window for all simulations.');
    area = findall(window, 'Type', 'uitextarea');
    assert(isscalar(area) && strcmp(area.Editable, 'off') && strcmp(area.WordWrap, 'off'));
    assert(numel(area.Value) == 1, 'Additional starts should be throttled.');
    assert(isempty(evalc('display.refresh(true);')));
    assert(numel(area.Value) == 20 && all(contains(string(area.Value), 'RUNNING')));
    % Runs 10 to 20 share an id width, so any shift here comes from the path.
    assert(isscalar(unique(cellfun(@(row) find(row == '|', 1), cellstr(area.Value(10:20))))), ...
        'Align columns across short and overlong deck paths.');
    assert(contains(area.Value{20}, '...') && contains(area.Value{20}, 'directory\run_20.dck'), ...
        'Truncate overlong deck paths from the left, keeping the deck name.');
    assert(contains(area.Value{1}, 'Elapsed: 01:01:01 | ETA: 25:00:00'), ...
        'Report elapsed and ETA in HH:MM:SS without wrapping at 24 hours.');
    assert(contains(area.Value{1}, '[##########----------] 1,234,567 /  8,760 (50%)'), ...
        'Group thousands and fill the bar to the reported fraction.');
    previous = area.Value;
    assert(isempty(evalc('display.refresh(true);')) && isequal(area.Value, previous));

    completed = struct('kind', 'QUEUE', 'event', 'COMPLETED');
    sims{1}.applyEvent(struct('kind', 'STATUS', 'status', 'DONE'));
    sims{1}.applyEvent(struct('kind', 'LOG', 'severity', 'warning'));
    sims{1}.markCompleted(completed);
    assert(isempty(evalc('display.simulationFinished(sims{1}); display.refresh();')), ...
        'Batch completions while other simulations remain.');
    output = evalc('display.refresh(true);');
    assert(contains(output, 'Status: DONE') && contains(output, 'N:0 W:1 F:0'));
    assert(sum(output == newline) == 1 && ~contains(output, char(8)));
    assert(numel(area.Value) == 19, 'Remove completed rows from the live window.');

    close(window);
    assert(~isgraphics(window));
    for index = 2:20
        sims{index}.applyEvent(struct('kind', 'STATUS', 'status', 'DONE'));
        sims{index}.markCompleted(completed);
        assert(isempty(evalc('display.simulationFinished(sims{index});')));
    end
    output = evalc('display.refresh();');
    assert(count(string(output), 'Status: DONE') == 19, ...
        'Flush the last batch even after the window is closed.');
    assert(isempty(evalc('display.refresh(true);')), 'Never repeat completed summaries.');
    extra = trnrun.Simulation('interrupted.dck', trnrun.SimulationConfig(), 21);
    assert(isempty(evalc('display.simulationStarted(extra);')));
    assert(isempty(setdiff(findall(groot, 'Type', 'figure'), before)), ...
        'Do not reopen a window the user closed.');
    output = evalc('delete(display);');
    assert(contains(output, 'interrupted.dck') && sum(output == newline) == 1, ...
        'Preserve interrupted progress on deletion.');
    clear cleanup

    display = trnrun.internal.Display(1);
    cleanup = onCleanup(@() delete(display)); %#ok<NASGU>
    evalc('display.simulationStarted(extra);');
    window = setdiff(findall(groot, 'Type', 'figure'), before);
    assert(isscalar(window));
    extra.markCompleted(completed);
    evalc('display.simulationFinished(extra); display.refresh();');
    area = findall(window, 'Type', 'uitextarea');
    assert(all(strlength(string(area.Value)) == 0), 'Clear stale rows after the last completion.');
    assert(isempty(evalc('delete(display);')), 'Do not print the last summary twice.');
    assert(~isgraphics(window), 'Deleting the display must close its window.');
    clear cleanup

    display = trnrun.internal.Display(0);
    assert(isempty(evalc('display.simulationStarted(extra); display.refresh(true); delete(display);')));
    assert(isempty(setdiff(findall(groot, 'Type', 'figure'), before)), ...
        'Disabled displays must not create windows.');
    fprintf('Display checks passed.\n');
end
