classdef CallbackRecorder < handle
    properties
        count = 0
        manager = []
        mode = 'record'
        last = []
    end

    methods
        function invoke(obj, simulation)
            obj.count = obj.count + 1;
            obj.last = simulation;
            switch obj.mode
                case 'reenter'
                    obj.manager.wait();
                case 'error'
                    error('testsupport:CallbackFailure', 'callback failed');
            end
        end
    end
end
