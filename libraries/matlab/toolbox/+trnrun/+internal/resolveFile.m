function path = resolveFile(path)
    %RESOLVEFILE Return the absolute path of an existing file, from MATLAB's current folder.

    mustBeFile(path);
    [~, info] = fileattrib(path);
    path = string(info.Name);
end
