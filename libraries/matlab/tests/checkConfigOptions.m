function checkConfigOptions()
    %CHECKCONFIGOPTIONS Check explicit constructor options against all properties.
    %   Add libraries/matlab and libraries/matlab/tests to the path before running.

    defaults = trnrun.SimulationConfig();
    names = properties(defaults);
    for index = 1:numel(names)
        name = names{index};
        config = trnrun.SimulationConfig(name, defaults.(name));
        assert(isequal(config, defaults), 'Option changed defaults: %s', name);
    end

    config = trnrun.SimulationConfig(watch_tmp=1, poll_ms=uint32(7));
    assert(isequal(config.watch_tmp, true));
    assert(isequal(config.poll_ms, 7));
    for index = 1:numel(names)
        name = names{index};
        if ~ismember(name, {'watch_tmp', 'poll_ms'})
            assert(isequal(config.(name), defaults.(name)), ...
                'Omitted option changed: %s', name);
        end
    end

    invalid = {{'unknown_option', 1}, {'poll_ms'}, {'poll_ms', 0}};
    for index = 1:numel(invalid)
        rejected = false;
        try
            trnrun.SimulationConfig(invalid{index}{:});
        catch
            rejected = true;
        end
        assert(rejected, 'Invalid option case %d was accepted.', index);
    end
end
