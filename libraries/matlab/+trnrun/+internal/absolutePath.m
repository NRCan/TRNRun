function path = absolutePath(value, argument_name)
%ABSOLUTEPATH Resolve a string or character-vector path against the current directory.

if nargin < 2
    argument_name = "path";
end

if isstring(value)
    if ~isscalar(value) || ismissing(value)
        error("trnrun:InvalidPath", "%s must be a string scalar or character vector.", argument_name);
    end
    value = char(value);
elseif ~ischar(value) || ~isrow(value)
    error("trnrun:InvalidPath", "%s must be a string scalar or character vector.", argument_name);
end

if isempty(value)
    error("trnrun:InvalidPath", "%s must not be empty.", argument_name);
end

try
    path = char(System.IO.Path.GetFullPath(value));
catch exception
    wrapped = MException("trnrun:InvalidPath", "Could not resolve %s '%s': %s", ...
        argument_name, value, exception.message);
    throwAsCaller(wrapped);
end
end
