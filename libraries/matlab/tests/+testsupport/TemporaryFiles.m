classdef TemporaryFiles < handle
    %TEMPORARYFILES Empty files used to exercise path validation without processes.

    properties (SetAccess = private)
        root
        deck
        runner
        trnexe
    end

    methods
        function obj = TemporaryFiles()
            obj.root = tempname;
            mkdir(obj.root);
            obj.deck = fullfile(obj.root, 'model unicode.dck');
            obj.runner = fullfile(obj.root, 'trnrun.exe');
            obj.trnexe = fullfile(obj.root, 'TrnEXE64.exe');
            touch(obj.deck);
            touch(obj.runner);
            touch(obj.trnexe);
        end

        function config = config(obj)
            config = trnrun.SimulationConfig( ...
                'trnrun_path', obj.runner, ...
                'trnexe_path', obj.trnexe);
        end

        function delete(obj)
            if isfolder(obj.root)
                try
                    rmdir(obj.root, 's');
                catch
                end
            end
        end
    end
end

function touch(path)
[file, message] = fopen(path, 'w');
if file < 0
    error('testsupport:FileCreateFailed', ...
        'Could not create %s: %s', path, message);
end
cleanup = onCleanup(@() fclose(file)); %#ok<NASGU>
fprintf(file, 'fixture');
end
