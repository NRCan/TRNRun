function path = additionalSoftwareExecutable(softwareName, executableName)
    %ADDITIONALSOFTWAREEXECUTABLE Locate a MATLAB-managed native executable.
    %   Source checkouts fall back to toolbox/bin, where native client builds
    %   are deployed for development and testing.

    packageFolder = fileparts(fileparts(mfilename("fullpath")));
    toolboxFolder = fileparts(packageFolder);
    installationMap = fullfile(packageFolder, "getInstallationLocation.mlx");

    installationFolder = fullfile(toolboxFolder, "bin");
    if isfile(installationMap)
        candidate = trnrun.getInstallationLocation(char(softwareName));
        if isfolder(candidate)
            installationFolder = candidate;
        end
    end

    path = string(fullfile(installationFolder, executableName));
end
