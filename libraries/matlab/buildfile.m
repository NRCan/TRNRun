function plan = buildfile()
    %BUILDFILE Package and test the Windows-only TRNRun MATLAB toolbox.
    %   Run buildtool from this folder in MATLAB R2023a or newer:
    %
    %       buildtool           % Package dist/trnrun-v<version>-win_amd64.mltbx
    %       buildtool test      % Run the unit tests in tests/
    %       buildtool verify    % Stage and validate package inputs
    %       buildtool links     % Check the release assets the toolbox cites
    %       buildtool clean     % Remove dist/
    %
    %   The archive is named for the version and platform it carries, so
    %   clean before packaging to keep one artifact per release:
    %
    %       buildtool clean package
    %
    %   Packaging does not depend on the tests, so a release archive never
    %   waits on a full suite run. Run both with: buildtool test package
    %
    %   The links task needs the GitHub release to exist, so it runs on its
    %   own after publishing rather than as part of packaging.

    plan = buildplan(localfunctions);
    plan("package").Dependencies = "verify";
    plan.DefaultTasks = "package";
end

function options = toolboxOptions()
    %TOOLBOXOPTIONS Configure toolbox metadata and packaging options.

    % Keep this identifier stable after publication so MATLAB recognises
    % subsequent releases as upgrades rather than separate toolboxes.
    identifier = "trnrun";

    options = matlab.addons.toolbox.ToolboxOptions(toolboxFolder(), identifier, ...
        ToolboxName="TRNRun", ...
        ToolboxVersion=trnrun.version(), ...
        Summary="Run, monitor, and orchestrate batches of TRNSYS simulations from MATLAB.", ...
        Description="Windows-only MATLAB client for the TRNRun runner and queue. " + ...
            "Run, monitor, and orchestrate batches of TRNSYS simulations. " + ...
            "Requires a separate installation of TRNSYS 17 or 18 on 64-bit Windows. " + ...
            "MATLAB R2021a compatibility is a target, not a runtime-verified guarantee.", ...
        AuthorName="Alex Lachance", ...
        AuthorEmail="alex.lachance@nrcan-rncan.gc.ca", ...
        AuthorCompany="Natural Resources Canada / Ressources naturelles Canada; " + ...
            "CanmetENERGY in Varennes / CanmetÉNERGIE à Varennes", ...
        ToolboxImageFile=fullfile(rootFolder(), "images", "trnrun-black-below.png"), ...
        ToolboxFiles=toolboxFiles(), ...
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
    pathCleanup = usingToolboxPath(); %#ok<NASGU>

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

    packaged = toolboxFiles();
    if isempty(packaged)
        error("trnrun:EmptyPackageFileList", ...
            "Package verification failed. No files selected from %s.", ...
            toolboxFolder());
    end
end

function linksTask(~)
    %LINKSTASK Confirm the release assets cited by the toolbox resolve.
    %   Packaging bakes version-specific GitHub URLs into the toolbox, but
    %   those assets exist only once the release is published. Failing the
    %   package task on them would make the first build of a new version
    %   impossible, so this task stays out of the dependency chain. Run it
    %   after publishing a release to catch a bad tag or a missed upload
    %   before an install does.

    pathCleanup = usingToolboxPath(); %#ok<NASGU>

    software = requiredAdditionalSoftware();
    urls = unique([string({software.DownloadURL}), string({software.LicenseURL})])';

    unreachable = urls(~arrayfun(@isReachableURL, urls));
    if ~isempty(unreachable)
        message = "Release assets cited by the toolbox are unreachable:" + ...
            newline + "  - " + strjoin(unreachable, newline + "  - ");
        error("trnrun:UnreachableReleaseAssets", "%s", message);
    end

    disp("Resolved " + numel(urls) + " release asset URLs.");
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

    toolboxVersion = string(trnrun.version());
    releaseURL = "https://github.com/NRCan/TRNRun/releases/download/" + ...
        toolboxVersion + "/";
    licenseURL = "https://raw.githubusercontent.com/NRCan/TRNRun/" + ...
        toolboxVersion + "/LICENSE";

    software = [ ...
        struct( ...
            "Name", "TRNRun", ...
            "Platform", "win64", ...
            "DownloadURL", releaseURL + "trnrun-v" + toolboxVersion + "-win_amd64.zip", ...
            "LicenseURL", licenseURL); ...
        struct( ...
            "Name", "TRNRunQ", ...
            "Platform", "win64", ...
            "DownloadURL", releaseURL + "trnrunq-v" + toolboxVersion + "-win_amd64.zip", ...
            "LicenseURL", licenseURL) ...
    ];
end

function tf = isReachableURL(url)
    %ISREACHABLEURL Report whether a HEAD request for URL succeeds.

    request = matlab.net.http.RequestMessage(matlab.net.http.RequestMethod.HEAD);
    try
        response = request.send(matlab.net.URI(url));
        tf = response.StatusCode == matlab.net.http.StatusCode.OK;
    catch
        tf = false;
    end
end

function cleanup = usingToolboxPath()
    %USINGTOOLBOXPATH Put the toolbox folder on the path for the caller's scope.
    %   The caller must keep the returned object alive; the path is restored
    %   when it goes out of scope, so a build never leaves the path dirty.

    addpath(toolboxFolder());
    cleanup = onCleanup(@() rmpath(toolboxFolder()));
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

function files = toolboxFiles()
    %TOOLBOXFILES List the files packaged as the toolbox.
    %   ToolboxOptions otherwise defaults to every file under the toolbox
    %   folder, so the exclusions are applied here rather than through an
    %   ignore file the packager may not honour. The native executables are
    %   installed separately from the URLs in the toolbox metadata, and the
    %   remaining exclusions are artifacts left behind by running examples.

    excludedFolders = ["bin", fullfile("examples", "runs")] + filesep;
    excludedExtensions = [".log", ".lst", ".tmp", ".pti"];

    entries = dir(fullfile(toolboxFolder(), "**", "*"));
    entries = entries(~[entries.isdir]);
    if isempty(entries)
        files = strings(0, 1);
        return
    end

    absolute = string(fullfile({entries.folder}, {entries.name}))';
    relative = extractAfter(absolute, strlength(toolboxFolder()) + 1);

    keep = ~startsWith(relative, excludedFolders) & ...
        ~endsWith(lower(relative), excludedExtensions);
    files = absolute(keep);
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
