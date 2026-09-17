function plan = buildfile()
    %BUILDFILE Package and test the Windows-only TRNRun MATLAB toolbox.
    %   Run buildtool from this folder in MATLAB R2023a or newer:
    %
    %       buildtool           % Package dist/trnrun-v<version>-win_amd64.mltbx
    %       buildtool test      % Run the unit tests in tests/
    %       buildtool verify    % Stage and validate package inputs
    %       buildtool clean     % Remove dist/
    %
    %   The archive is named for the version and platform it carries, so
    %   clean before packaging to keep one artifact per release:
    %
    %       buildtool clean package
    %
    %   Packaging does not depend on the tests, so a release archive never
    %   waits on a full suite run. Run both with: buildtool test package

    plan = buildplan(localfunctions);
    plan("package").Dependencies = "verify";
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
        ToolboxImageFile=fullfile(rootFolder(), "images", "trnrun-black-below.png"), ...
        ToolboxMatlabPath=toolboxFolder(), ...
        RequiredAdditionalSoftware=requiredAdditionalSoftware(), ...
        MinimumMatlabRelease="R2021a", ...
        SupportedPlatforms=struct( ...
            "Win64", true, ...
            "Glnxa64", false, ...
            "Mac", false, ...
            "MatlabOnline", false), ...
        OutputFile=fullfile(distFolder(), ...
            "trnrun-v" + trnrun.version() + "-win_amd64.mltbx"));
end

function packageTask(~)
    %PACKAGETASK Package the verified toolbox in dist/.

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

function verifyTask(~)
    %VERIFYTASK Stage canonical documentation and validate package inputs.

    stagePackageFiles();

    required = [ ...
        fullfile(toolboxFolder(), "LICENSE"); ...
        fullfile(toolboxFolder(), "README.md"); ...
        fullfile(toolboxFolder(), "functionSignatures.json"); ...
        fullfile(toolboxFolder(), "+trnrun", "version.m"); ...
        fullfile(rootFolder(), "images", "trnrun-black-below.png"); ...
        fullfile(toolboxFolder(), "+trnrun", "getInstallationLocation.mlx") ...
    ];
    missing = required(~isfile(required));
    if ~isempty(missing)
        message = "Package verification failed. Missing required files:" + ...
            newline + "  - " + strjoin(missing, newline + "  - ");
        error("trnrun:MissingPackageFiles", "%s", message);
    end
end

function testTask(~)
    %TESTTASK Run the unit tests in tests/ and fail the build on any failure.
    %   The tests need Windows and the queue executable staged by the native
    %   build, but never TRNSYS.

    results = runtests(testsFolder());
    disp(table(results));
    assertSuccess(results);
end

function cleanTask(~)
    %CLEANTASK Remove generated distribution artifacts.

    if isfolder(distFolder())
        rmdir(distFolder(), "s");
    end
end

function software = requiredAdditionalSoftware()
    %REQUIREDADDITIONALSOFTWARE Describe native clients downloaded at install time.

    version = string(trnrun.version());
    releaseURL = "https://github.com/NRCan/TRNRun/releases/download/" + ...
        version + "/";
    licenseURL = "https://raw.githubusercontent.com/NRCan/TRNRun/" + ...
        version + "/LICENSE";

    software = [ ...
        struct( ...
            "Name", "TRNRun", ...
            "Platform", "win64", ...
            "DownloadURL", releaseURL + "trnrun-v" + version + "-win_amd64.zip", ...
            "LicenseURL", licenseURL); ...
        struct( ...
            "Name", "TRNRunQ", ...
            "Platform", "win64", ...
            "DownloadURL", releaseURL + "trnrunq-v" + version + "-win_amd64.zip", ...
            "LicenseURL", licenseURL) ...
    ];
end

function stagePackageFiles()
    %STAGEPACKAGEFILES Refresh generated package files from canonical sources.

    sources = [ ...
        fullfile(rootFolder(), "README.md"); ...
        fullfile(repositoryFolder(), "LICENSE") ...
    ];
    destinations = [ ...
        fullfile(toolboxFolder(), "README.md"); ...
        fullfile(toolboxFolder(), "LICENSE") ...
    ];

    missing = sources(~isfile(sources));
    if ~isempty(missing)
        message = "Cannot stage package files. Missing canonical sources:" + ...
            newline + "  - " + strjoin(missing, newline + "  - ");
        error("trnrun:MissingPackageSources", "%s", message);
    end

    for index = 1:numel(sources)
        copyfile(sources(index), destinations(index), "f");
    end
end

function folder = rootFolder()
    %ROOTFOLDER Return the folder containing this build file.

    folder = string(fileparts(mfilename("fullpath")));
end

function folder = repositoryFolder()
    %REPOSITORYFOLDER Return the repository root containing LICENSE.

    folder = fileparts(fileparts(rootFolder()));
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the folder packaged as the toolbox.

    folder = fullfile(rootFolder(), "toolbox");
end

function folder = testsFolder()
    %TESTSFOLDER Return the folder holding the unit tests.
    %   It sits beside the toolbox folder, so tests are never packaged.

    folder = fullfile(rootFolder(), "tests");
end

function folder = distFolder()
    %DISTFOLDER Return the folder containing generated archives.

    folder = fullfile(rootFolder(), "dist");
end
