function results = runTransportTests()
%RUNTRANSPORTTESTS Run live Windows pipe and Job Object tests.

matlab_root = fileparts(fileparts(mfilename('fullpath')));
tests_root = fileparts(mfilename('fullpath'));
addpath(matlab_root);
cleanup = onCleanup(@() rmpath(matlab_root)); %#ok<NASGU>
results = runtests(fullfile(tests_root, 'transport'));
assertSuccess(results);
end
