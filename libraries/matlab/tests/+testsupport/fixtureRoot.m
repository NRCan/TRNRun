function root = fixtureRoot()
%FIXTUREROOT Return the shared language-neutral contract fixture directory.

here = fileparts(mfilename('fullpath'));
tests = fileparts(here);
matlab_root = fileparts(tests);
libraries = fileparts(matlab_root);
root = fullfile(libraries, 'tests', 'fixtures');
end
