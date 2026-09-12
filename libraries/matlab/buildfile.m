function plan = buildfile()
%BUILDFILE Package the TRNRun MATLAB toolbox.
%   Run buildtool from this folder in MATLAB R2023a or newer:
%
%       buildtool           % package dist/TRNRun.mltbx
%       buildtool clean     % remove dist/
%
%   Packaging ships everything under toolbox/, so generated example output
%   is deleted first.
%
%   This task packages whatever toolbox/ already holds. The repository
%   justfile stages the license, README and native executables into it
%   before calling buildtool; run `just matlab` for a complete archive.
%
%   Windows-only.

plan = buildplan(localfunctions);

plan.DefaultTasks = "package";
end

function packageTask(~)
% Write dist/TRNRun.mltbx from the toolbox folder.

if isMATLABReleaseOlderThan("R2023a")
    error("trnrun:BuildReleaseTooOld", ...
        "Packaging requires MATLAB R2023a or newer; this is %s.", ...
        matlabRelease().Release);
end

root = rootFolder();
distFolder = fullfile(root, "dist");
if ~isfolder(distFolder)
    mkdir(distFolder);
end

pruneExampleOutput();

toolboxFolder = fullfile(root, "toolbox");
addpath(toolboxFolder);

options = matlab.addons.toolbox.ToolboxOptions(toolboxFolder, toolboxIdentifier(), ...
    ToolboxName="TRNRun", ...
    ToolboxVersion=trnrun.version(), ...
    Summary="Submit, monitor, and inspect TRNSYS simulations from MATLAB.", ...
    Description="Windows MATLAB client for the TRNRun runner and queue. " + ...
        "Requires separately installed TRNSYS 17 or 18. R2021a compatibility " + ...
        "is a target, not a runtime-verified guarantee.", ...
    AuthorName="Natural Resources Canada", ...
    AuthorCompany="Natural Resources Canada", ...
    ToolboxImageFile=fullfile(root, "images", "TRNRun.jpg"), ...
    ToolboxMatlabPath=toolboxFolder, ...
    MinimumMatlabRelease="R2021a", ...
    SupportedPlatforms=struct("Win64", true, "Glnxa64", false, ...
        "Mac", false, "MatlabOnline", false), ...
    OutputFile=fullfile(distFolder, "TRNRun.mltbx"));

matlab.addons.toolbox.packageToolbox(options);
end

function identifier = toolboxIdentifier()
%TOOLBOXIDENTIFIER Return the permanent unique identifier for this toolbox.
%   MATLAB uses this to recognise an install as an upgrade of TRNRun rather
%   than a second, unrelated toolbox. Never change it: installed users would
%   end up with two copies side by side.

identifier = "5c1729e8-6f49-4a8b-baa9-190f694ccbec";
end

function pruneExampleOutput()
%PRUNEEXAMPLEOUTPUT Delete generated example output before packaging.
%   Running the examples writes decks and TRNSYS output into
%   toolbox/examples, and packaging ships everything under toolbox/
%   regardless of .gitignore. Every file removed here is regenerable by
%   rerunning the example that produced it.

examples = fullfile(rootFolder(), "toolbox", "examples");

runsFolder = fullfile(examples, "runs");
if isfolder(runsFolder)
    rmdir(runsFolder, "s");
end

% Mirrors the TRNSYS output extensions ignored by Git.
for pattern = ["*.log" "*.lst" "*.tmp" "*.PTI"]
    stale = dir(fullfile(examples, "dck", pattern));
    for index = 1:numel(stale)
        delete(fullfile(stale(index).folder, stale(index).name));
    end
end
end

function cleanTask(~)
% Remove generated distribution artifacts.

distFolder = fullfile(rootFolder(), "dist");
if isfolder(distFolder)
    rmdir(distFolder, "s");
end
end

function folder = rootFolder()
%ROOTFOLDER Return the folder holding this build file.

folder = string(fileparts(mfilename("fullpath")));
end
