function path = additionalSoftwareExecutable(softwareName, executableName)
    %ADDITIONALSOFTWAREEXECUTABLE Locate an installed native executable, else the one in toolbox/bin.

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
