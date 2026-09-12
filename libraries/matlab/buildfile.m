function plan = buildfile()
    %BUILDFILE Package the Windows-only TRNRun MATLAB toolbox.
    %   Run buildtool from this folder in MATLAB R2023a or newer:
    %
    %       buildtool           % Package dist/TRNRun.mltbx
    %       buildtool clean     % Remove dist/

    plan = buildplan(localfunctions);
    plan.DefaultTasks = "package";
end

function options = toolboxOptions()
    %TOOLBOXOPTIONS Configure toolbox metadata and packaging options.

    % Keep this identifier stable after publication so MATLAB recognises
    % subsequent releases as upgrades rather than separate toolboxes.
    identifier = "ca-nrcan-trnrun";

    options = matlab.addons.toolbox.ToolboxOptions(toolboxFolder(), identifier, ...
        ToolboxName="TRNRun", ...
        ToolboxVersion=trnrun.version(), ...
        Summary="Run, monitor, and orchestrate batches of TRNSYS simulations from MATLAB.", ...
        Description="Windows-only MATLAB client for the TRNRun runner and queue. " + ...
            "Run, monitor, and orchestrate batches of TRNSYS simulations. " + ...
            "Requires a separate installation of TRNSYS 17 or 18 on 64-bit Windows. " + ...
            "MATLAB R2021a compatibility is a target, not a runtime-verified guarantee.", ...
        AuthorName="Alex Lachance", ...
        AuthorCompany="Natural Resources Canada / Ressources naturelles Canada; " + ...
            "CanmetENERGY in Varennes / CanmetÉNERGIE à Varennes", ...
        ToolboxImageFile=fullfile(rootFolder(), "images", "TRNRun.jpg"), ...
        ToolboxMatlabPath=toolboxFolder(), ...
        MinimumMatlabRelease="R2021a", ...
        SupportedPlatforms=struct( ...
            "Win64", true, ...
            "Glnxa64", false, ...
            "Mac", false, ...
            "MatlabOnline", false), ...
        OutputFile=fullfile(distFolder(), "TRNRun.mltbx"));
end

function packageTask(~)
    %PACKAGETASK Package the toolbox as dist/TRNRun.mltbx.

    if isMATLABReleaseOlderThan("R2023a")
        error("trnrun:BuildReleaseTooOld", ...
            "Packaging requires MATLAB R2023a or newer; this is %s.", ...
            matlabRelease().Release);
    end

    if ~isfolder(distFolder())
        mkdir(distFolder());
    end

    % Make trnrun.version available when evaluating toolbox options.
    addpath(toolboxFolder());

    matlab.addons.toolbox.packageToolbox(toolboxOptions());
end

function cleanTask(~)
    %CLEANTASK Remove generated distribution artifacts.

    if isfolder(distFolder())
        rmdir(distFolder(), "s");
    end
end

function folder = rootFolder()
    %ROOTFOLDER Return the folder containing this build file.

    folder = string(fileparts(mfilename("fullpath")));
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the folder packaged as the toolbox.

    folder = fullfile(rootFolder(), "toolbox");
end

function folder = distFolder()
    %DISTFOLDER Return the folder containing generated archives.

    folder = fullfile(rootFolder(), "dist");
end
