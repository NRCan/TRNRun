function results = runUnitTests()
%RUNUNITTESTS Run process-free MATLAB client tests.

matlab_root = fileparts(fileparts(mfilename('fullpath')));
tests_root = fileparts(mfilename('fullpath'));
addpath(matlab_root);
cleanup = onCleanup(@() rmpath(matlab_root)); %#ok<NASGU>
results = runtests(fullfile(tests_root, 'unit'), 'IncludeSubfolders', true);
assertSuccess(results);
end
