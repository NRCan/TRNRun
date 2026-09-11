function root = libraryRoot()
%LIBRARYROOT Return the installed MATLAB client root directory.

here = fileparts(mfilename("fullpath"));
root = fileparts(fileparts(here));
end
