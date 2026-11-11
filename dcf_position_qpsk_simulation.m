% DCF_POSITION_QPSK_SIMULATION
% Impact of the in-line dispersion-compensating fiber (DCF) position in a
% dispersion-managed, multi-span QPSK optical link.
%
% Two span configurations are compared:
%   Configuration A: SMF -> DCF -> amplifier
%   Configuration B: DCF -> SMF -> amplifier
% The in-line DCF compensates 80% of the SMF dispersion in every span. A
% final post-compensating DCF after the last span removes the residual
% accumulated first-order dispersion at 1550 nm.
%
% Three propagation cases separate the contribution of each fiber:
%   'linear'             : Kerr nonlinearity disabled in all fibers
%   'smf nonlinear only' : Kerr nonlinearity in the SMF only
%   'full nonlinear'     : Kerr nonlinearity in SMF, in-line DCF and post-DCF
%
% Outputs (written to an "outputs" folder next to this file):
%   - SNR vs launch power for every case and configuration
%   - SNR difference between A and B in the full nonlinear case
%   - BER vs launch power on a logarithmic axis
%   - Received QPSK constellations at selected launch powers
%   - CSV summary of the optimum operating points
%   - MAT file with all results (reused on later runs, see forceRecompute)
%
% Requirements: MATLAB R2019b or newer and the Optilux toolbox
%               (https://optilux.sourceforge.io).
%
% Author: Maher Ghaly, University of Parma

clear
clc
close all

%% User settings
% Path to the Optilux toolbox folder (download from https://optilux.sourceforge.io).
optiluxPath = '';

% true : run the full propagation sweep (slow).
% false: reuse outputs/dcf_position_qpsk_results.mat if it exists, and only
%        re-plot. Set to true again after changing any simulation parameter.
forceRecompute = false;

runConstellationPlots = true;   % re-simulate selected points and plot constellations
runStepConvergence    = false;  % SSFM step-size convergence check (slow)

%% Paths and output folder
if isempty(optiluxPath) || ~exist(optiluxPath, 'dir')
    error(['Optilux not found. Set "optiluxPath" at the top of this script ', ...
        'to the folder where Optilux is installed (https://optilux.sourceforge.io).']);
end
addpath(optiluxPath);

workDir = fileparts(mfilename('fullpath'));
outDir = fullfile(workDir, 'outputs');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
resultsFile = fullfile(outDir, 'dcf_position_qpsk_results.mat');

% Default figure style: white background, black axes and text, so that the
% saved figures look the same regardless of the MATLAB desktop theme.
set(groot, 'defaultFigureColor', 'w');
set(groot, 'defaultAxesColor', 'w');
set(groot, 'defaultAxesXColor', 'k');
set(groot, 'defaultAxesYColor', 'k');
set(groot, 'defaultTextColor', 'k');
set(groot, 'defaultLegendTextColor', 'k');

%% Global simulation parameters
Nsymb = 4096;           % number of QPSK symbols
Nt = 16;                % samples per symbol
symbrate = 10;          % symbol rate [Gbaud]
lam = 1550;             % carrier wavelength [nm]
modfor = 'qpsk';        % modulation format

Nsamp = Nsymb*Nt;       % total number of samples
fs = symbrate*Nt;       % sampling frequency [GHz]
inigstate(Nsamp, fs);   % initialize the Optilux global simulation state

rng(1);                 % fixed seed: repeatable bit pattern and ASE noise

%% Transmitter and receiver parameters
% Transmitter: root-raised-cosine pulse shaping. The arcsine pre-emphasis
% compensates the sinusoidal transfer function of the IQ Mach-Zehnder
% modulator, so the optical field follows the electrical drive signal.
tx.rolloff = 0.01;              % RRC roll-off factor
tx.emph = 'asin';               % arcsine pre-emphasis for the IQ modulator

% Coherent receiver and DSP.
rx.modformat = modfor;          % modulation format
rx.sync.type = 'da';            % data-aided time synchronization
rx.sync.interp = 'nearest';     % fast timing recovery (+/- 1 sample accuracy)
rx.oftype = 'gauss';            % optical filter shape (unused: obw = Inf)
rx.obw = Inf;                   % no optical bandpass filtering
rx.eftype = 'rootrc';           % electrical filter matched to the TX pulse
rx.ebw = 0.5;                   % electrical bandwidth, normalized to symbol rate
rx.epar = tx.rolloff;           % roll-off of the matched filter
rx.type = 'bin';                % hard decisions returned as a binary pattern

% Transmitted QPSK signal.
[pat, patbin] = datapattern(Nsymb, 'rand', struct('format', modfor)); % random symbol pattern
[elec, normFact] = digitalmod(pat, modfor, symbrate, 'rootrc', tx);   % electrical drive signal
nBits = numel(patbin);          % bits per simulation point (8192)

%% Fiber map
spanLengthKm = 100;             % SMF length per span [km]
inlineComp = 0.80;              % in-line DCF compensates 80% of the span dispersion

% Standard single-mode fiber (SMF).
smfBase.length = spanLengthKm*1e3;     % length [m]
smfBase.lambda = lam;                  % reference wavelength [nm]
smfBase.alphadB = 0.2;                 % attenuation [dB/km]
smfBase.disp = 17;                     % dispersion [ps/(nm km)]
smfBase.slope = 0.057;                 % dispersion slope [ps/(nm^2 km)]
smfBase.pmdpar = 0;                    % PMD disabled
smfBase.aeff = 80;                     % effective area [um^2]
smfBase.n2 = 2.5e-20;                  % nonlinear refractive index [m^2/W]
smfBase.ismanakov = false;             % scalar NLSE (single polarization)
smfBase.dzmax = 2e4;                   % maximum SSFM step [m]
smfBase.trace = false;                 % no propagation progress messages

% Dispersion-compensating fiber (DCF). It starts from the SMF structure so
% that every field required by Optilux exists, then the DCF values are set.
dcfBase = smfBase;
dcfBase.alphadB = 0.6;                 % attenuation [dB/km]
dcfBase.disp = -100;                   % dispersion [ps/(nm km)]
dcfBase.slope = 0;                     % dispersion slope [ps/(nm^2 km)]
dcfBase.aeff = 20;                     % effective area [um^2]
dcfBase.dzmax = 5e3;                   % maximum SSFM step [m]
% L_DCF = C_inline * D_SMF * L_SMF / |D_DCF| = 13.6 km
dcfBase.length = inlineComp*smfBase.disp*spanLengthKm/abs(dcfBase.disp)*1e3; % [m]

% Residual dispersion left in each span after in-line compensation [ps/nm].
residualDispPerSpan = smfBase.disp*spanLengthKm + dcfBase.disp*dcfBase.length*1e-3;

%% Sweep settings
powerdBm = -8:2:10;             % launch powers [dBm]: ASE-limited to nonlinear regime
spanList = [5 10 15];           % number of spans
caseNames = {'linear', 'smf nonlinear only', 'full nonlinear'};
configNames = {'A: SMF-DCF', 'B: DCF-SMF'};

%% Propagation sweep (or load saved results)
if ~forceRecompute && exist(resultsFile, 'file')
    fprintf('Loading saved results from:\n%s\n', resultsFile);
    load(resultsFile, 'results', 'powerdBm', 'spanList', 'caseNames', ...
        'configNames', 'spanLengthKm', 'inlineComp', 'residualDispPerSpan');
else
    results = struct();

    for iSpan = 1:numel(spanList)
        Nspan = spanList(iSpan);

        % The post-DCF removes the residual dispersion accumulated over all spans.
        postDcfBase = dcfBase;
        postDcfBase.length = abs(Nspan*residualDispPerSpan/postDcfBase.disp)*1e3; % [m]

        for iCase = 1:numel(caseNames)
            for iConfig = 1:numel(configNames)
                snrCurve = zeros(size(powerdBm));
                berCurve = zeros(size(powerdBm));

                for iPow = 1:numel(powerdBm)
                    PdBm = powerdBm(iPow);
                    Plin = 10.^(PdBm/10);  % launch power [mW]

                    % Local copies, so each case can change n2 without
                    % modifying the base fiber definitions.
                    smf = smfBase;
                    dcf = dcfBase;
                    postDcf = postDcfBase;

                    % Enable or disable the Kerr effect fiber by fiber
                    % (n2 = 0 makes the propagation in that fiber linear).
                    switch iCase
                        case 1  % linear
                            smf.n2 = 0;
                            dcf.n2 = 0;
                            postDcf.n2 = 0;
                        case 2  % SMF nonlinear only
                            smf.n2 = 2.5e-20;
                            dcf.n2 = 0;
                            postDcf.n2 = 0;
                        case 3  % full nonlinear
                            smf.n2 = 2.5e-20;
                            dcf.n2 = 2.5e-20;
                            postDcf.n2 = 2.5e-20;
                    end

                    % The amplifier gain recovers the total span loss (SMF + DCF).
                    amp.gain = smf.length*smf.alphadB*1e-3 + dcf.length*dcf.alphadB*1e-3; % [dB]
                    amp.f = 6;             % noise figure [dB]

                    % Laser source and IQ modulation.
                    E = lasersource(Plin, lam, struct('pol', 'single'));
                    E = iqmodulator(E, elec, struct('norm', normFact));

                    % Multi-span propagation. The two configurations differ
                    % only in the order of SMF and DCF inside each span.
                    for ns = 1:Nspan
                        if iConfig == 1
                            E = fiber(E, smf);
                            E = fiber(E, dcf);
                        else
                            E = fiber(E, dcf);
                            E = fiber(E, smf);
                        end
                        E = ampliflat(E, amp);
                    end

                    % Final post-compensation of the residual dispersion.
                    E = fiber(E, postDcf);

                    % Coherent detection, DSP and hard decision.
                    rsig = rxfrontend(E, lam, symbrate, rx);
                    akhat = rxdsp(rsig, symbrate, pat, rx);
                    patbinhat = samp2pat(akhat, modfor, rx);

                    % SNR (Es/N0) estimated from the samples, and BER by
                    % direct error counting.
                    snrCurve(iPow) = samp2snr(pat, akhat, modfor);
                    berCurve(iPow) = mean(patbin(:) ~= patbinhat(:));

                    fprintf('N=%d, case=%s, config=%s, P=%+.1f dBm, SNR=%.2f dB, BER=%.3g\n', ...
                        Nspan, caseNames{iCase}, configNames{iConfig}, PdBm, snrCurve(iPow), berCurve(iPow));
                end

                results(iSpan, iCase, iConfig).Nspan = Nspan;
                results(iSpan, iCase, iConfig).caseName = caseNames{iCase};
                results(iSpan, iCase, iConfig).configName = configNames{iConfig};
                results(iSpan, iCase, iConfig).powerdBm = powerdBm;
                results(iSpan, iCase, iConfig).snr = snrCurve;
                results(iSpan, iCase, iConfig).ber = berCurve;
            end
        end
    end

    save(resultsFile, 'results', 'powerdBm', 'spanList', 'caseNames', ...
        'configNames', 'spanLengthKm', 'inlineComp', 'residualDispPerSpan');
    writeSummaryCsv(results, powerdBm, caseNames, configNames, spanList, outDir);
end

%% Plots
plotCaseComparison(results, powerdBm, caseNames, configNames, spanList, outDir);
plotFullNonlinearDifference(results, powerdBm, spanList, outDir);
plotBerComparison(results, powerdBm, caseNames, configNames, spanList, nBits, outDir);
plotBerFullNonlinearAllSpans(results, powerdBm, caseNames, configNames, spanList, nBits, outDir);

%% Constellation plots
if runConstellationPlots
    plotConstellations(smfBase, dcfBase, residualDispPerSpan, spanList, ...
        lam, symbrate, rx, pat, patbin, elec, normFact, modfor, outDir);
end

%% SSFM step-size convergence test
% Compares coarse and fine SSFM steps at the high-power points, where the
% nonlinear effects (and therefore the numerical error) are strongest.
if runStepConvergence
    convergencePowers = [8 10];    % launch powers [dBm]
    convergenceNspan = 10;
    runStepSizeConvergence(smfBase, dcfBase, residualDispPerSpan, ...
        convergenceNspan, convergencePowers, lam, symbrate, rx, pat, patbin, ...
        elec, normFact, modfor, outDir);
end

fprintf('\nSaved results and plots in:\n%s\n', outDir);

%% Local functions
% Plotting and simulation helpers, kept as local functions so the main
% script stays short and every figure is produced the same way.

function plotCaseComparison(results, powerdBm, caseNames, configNames, spanList, outDir)
    % SNR vs launch power for every propagation case and configuration
    % (3 cases x 2 configurations = 6 curves per figure).
    markers = {'o-', 's-', '^-', 'd-', 'x-', '*-'};
    for iSpan = 1:numel(spanList)
        fig = figure('Color', 'w', 'InvertHardcopy', 'off');
        labels = {};
        hold on
        k = 1;
        for iCase = 1:numel(caseNames)
            for iConfig = 1:numel(configNames)
                plot(powerdBm, results(iSpan, iCase, iConfig).snr, markers{k}, 'LineWidth', 1.4);
                labels{k} = sprintf('%s, %s', configNames{iConfig}, caseNames{iCase}); %#ok<AGROW>
                k = k + 1;
            end
        end
        grid on
        xlabel('Launch power [dBm]')
        ylabel('Estimated SNR [dB]')
        title(sprintf('DCF position comparison, N_{span} = %d', spanList(iSpan)))
        legend(labels, 'Location', 'southwest', 'FontSize', 8)
        formatFigure(gca);
        saveas(fig, fullfile(outDir, sprintf('snr_all_cases_Nspan_%d.png', spanList(iSpan))));
        close(fig)
    end
end

function plotFullNonlinearDifference(results, powerdBm, spanList, outDir)
    % Full nonlinear case only (Kerr effect in SMF and DCF): SNR of both
    % configurations, and the SNR difference A - B.
    for iSpan = 1:numel(spanList)
        snrA = results(iSpan, 3, 1).snr;
        snrB = results(iSpan, 3, 2).snr;

        fig = figure('Color', 'w', 'InvertHardcopy', 'off');
        plot(powerdBm, snrA, 'o-', powerdBm, snrB, 's-', 'LineWidth', 1.5)
        grid on
        xlabel('Launch power [dBm]')
        ylabel('Estimated SNR [dB]')
        title(sprintf('Full nonlinear case, N_{span} = %d', spanList(iSpan)))
        legend('A: SMF-DCF', 'B: DCF-SMF', 'Location', 'best')
        formatFigure(gca);
        saveas(fig, fullfile(outDir, sprintf('snr_full_nonlinear_Nspan_%d.png', spanList(iSpan))));
        close(fig)

        fig = figure('Color', 'w', 'InvertHardcopy', 'off');
        plot(powerdBm, snrA - snrB, 'o-', 'LineWidth', 1.5)
        yline(0, 'k--')
        grid on
        xlabel('Launch power [dBm]')
        ylabel('SNR_A - SNR_B [dB]')
        title(sprintf('DCF position penalty, full nonlinear, N_{span} = %d', spanList(iSpan)))
        formatFigure(gca);
        saveas(fig, fullfile(outDir, sprintf('snr_difference_full_nonlinear_Nspan_%d.png', spanList(iSpan))));
        close(fig)
    end
end

function plotBerComparison(results, powerdBm, caseNames, configNames, spanList, nBits, outDir)
    % BER vs launch power for every case and configuration, on a log axis.
    % Colour = propagation case, solid circles = A, dashed squares = B.
    caseColors = [0.00 0.45 0.74;    % linear
                  0.85 0.33 0.10;    % SMF nonlinear only
                  0.47 0.67 0.19];   % full nonlinear
    configStyle  = {'-', '--'};
    configMarker = {'o', 's'};

    for iSpan = 1:numel(spanList)
        fig = figure('Color', 'w', 'InvertHardcopy', 'off');
        ax = axes(fig);
        hold(ax, 'on')
        h = gobjects(0);
        labels = {};
        for iCase = 1:numel(caseNames)
            for iConfig = 1:numel(configNames)
                h(end+1) = plotBerCurve(ax, powerdBm, results(iSpan, iCase, iConfig).ber, nBits, ...
                    caseColors(iCase, :), configStyle{iConfig}, configMarker{iConfig}); %#ok<AGROW>
                labels{end+1} = sprintf('%s, %s', configNames{iConfig}, caseNames{iCase}); %#ok<AGROW>
            end
        end
        finishBerAxes(ax, nBits);
        title(ax, sprintf('BER comparison, N_{span} = %d', spanList(iSpan)))
        legend(h, labels, 'Location', 'northwest', 'FontSize', 8)
        formatFigure(ax);
        saveas(fig, fullfile(outDir, sprintf('ber_log_all_cases_Nspan_%d.png', spanList(iSpan))));
        close(fig)
    end
end

function plotBerFullNonlinearAllSpans(results, powerdBm, caseNames, configNames, spanList, nBits, outDir)
    % BER vs launch power in the full nonlinear case, all span counts in one
    % figure. Colour = number of spans, solid circles = A, dashed squares = B.
    iFull = find(strcmp(caseNames, 'full nonlinear'), 1);
    spanColors = [0.00 0.45 0.74;    % blue
                  0.80 0.15 0.15;    % red
                  0.49 0.18 0.56];   % purple
    configStyle  = {'-', '--'};
    configMarker = {'o', 's'};

    fig = figure('Color', 'w', 'InvertHardcopy', 'off');
    ax = axes(fig);
    hold(ax, 'on')
    h = gobjects(0);
    labels = {};
    for iSpan = 1:numel(spanList)
        color = spanColors(mod(iSpan-1, size(spanColors, 1)) + 1, :);
        for iConfig = 1:numel(configNames)
            h(end+1) = plotBerCurve(ax, powerdBm, results(iSpan, iFull, iConfig).ber, nBits, ...
                color, configStyle{iConfig}, configMarker{iConfig}); %#ok<AGROW>
            labels{end+1} = sprintf('%s, N_{span} = %d', configNames{iConfig}, spanList(iSpan)); %#ok<AGROW>
        end
    end
    finishBerAxes(ax, nBits);
    title(ax, 'BER, full nonlinear case')
    legend(h, labels, 'Location', 'northwest', 'FontSize', 8)
    formatFigure(ax);
    saveas(fig, fullfile(outDir, 'ber_log_full_nonlinear_all_spans.png'));
    close(fig)
end

function hLine = plotBerCurve(ax, powerdBm, ber, nBits, color, lineStyle, marker)
    % Draw one BER curve. A log axis cannot show BER = 0, so zero-error
    % points are placed at half the one-error resolution, 0.5/nBits, and
    % drawn with hollow markers.
    zeroIdx = (ber == 0);
    berPlot = ber;
    berPlot(zeroIdx) = 0.5/nBits;
    hLine = plot(ax, powerdBm, berPlot, [lineStyle marker], 'Color', color, ...
        'MarkerFaceColor', color, 'LineWidth', 1.3, 'MarkerSize', 6);
    if any(zeroIdx)
        plot(ax, powerdBm(zeroIdx), berPlot(zeroIdx), marker, 'Color', color, ...
            'MarkerFaceColor', 'w', 'LineWidth', 1.3, 'MarkerSize', 6, ...
            'HandleVisibility', 'off');
    end
end

function finishBerAxes(ax, nBits)
    % Logarithmic BER axis. The scale is set explicitly AFTER plotting:
    % when "hold on" is active before the first semilogy call, MATLAB keeps
    % the default linear scale.
    set(ax, 'YScale', 'log');
    ylim(ax, [10^floor(log10(0.5/nBits)) 1]);
    yline(ax, 1/nBits, 'k:', 'LineWidth', 1, 'HandleVisibility', 'off');
    text(ax, ax.XLim(2), 1/nBits, sprintf('1 error (BER = 1/%d)  ', nBits), ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'FontSize', 8);
    text(ax, ax.XLim(2), ax.YLim(1), 'hollow = 0 errors observed  ', ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'FontSize', 8);
    grid(ax, 'on')
    ax.YMinorGrid = 'on';
    xlabel(ax, 'Launch power [dBm]')
    ylabel(ax, 'Estimated BER')
end

function writeSummaryCsv(results, powerdBm, caseNames, configNames, spanList, outDir)
    % CSV summary: optimum launch power, maximum SNR, and SNR at the lowest
    % and highest launch power, for every span count, case and configuration.
    NspanCol = [];
    CaseCol = {};
    ConfigCol = {};
    BestPowerCol = [];
    BestSnrCol = [];
    SnrAtMinPowerCol = [];
    SnrAtMaxPowerCol = [];

    for iSpan = 1:numel(spanList)
        for iCase = 1:numel(caseNames)
            for iConfig = 1:numel(configNames)
                snr = results(iSpan, iCase, iConfig).snr;
                [bestSnr, idx] = max(snr);
                NspanCol(end+1, 1) = spanList(iSpan); %#ok<AGROW>
                CaseCol{end+1, 1} = caseNames{iCase}; %#ok<AGROW>
                ConfigCol{end+1, 1} = configNames{iConfig}; %#ok<AGROW>
                BestPowerCol(end+1, 1) = powerdBm(idx); %#ok<AGROW>
                BestSnrCol(end+1, 1) = bestSnr; %#ok<AGROW>
                SnrAtMinPowerCol(end+1, 1) = snr(1); %#ok<AGROW>
                SnrAtMaxPowerCol(end+1, 1) = snr(end); %#ok<AGROW>
            end
        end
    end

    summary = table(NspanCol, CaseCol, ConfigCol, BestPowerCol, BestSnrCol, ...
        SnrAtMinPowerCol, SnrAtMaxPowerCol, ...
        'VariableNames', {'Nspan', 'Case', 'Configuration', 'BestPower_dBm', ...
        'BestSNR_dB', 'SNR_at_min_power_dB', 'SNR_at_max_power_dB'});
    safeWriteTable(summary, fullfile(outDir, 'dcf_position_qpsk_summary.csv'));
end

function runStepSizeConvergence(smfBase, dcfBase, residualDispPerSpan, Nspan, ...
    testPowers, lam, symbrate, rx, pat, patbin, elec, normFact, modfor, outDir)
    % Numerical reliability check: compares the baseline SSFM step sizes
    % with smaller ones at high launch powers, in the full nonlinear case.
    % The same random seed is used for the coarse and fine runs, so any
    % difference comes from the step size only.

    stepNames = {'coarse: SMF 20 km, DCF 5 km', 'fine: SMF 5 km, DCF 1 km'};
    smfDzmax = [20e3 5e3];
    dcfDzmax = [5e3 1e3];
    configNames = {'A: SMF-DCF', 'B: DCF-SMF'};

    StepCol = {};
    ConfigCol = {};
    PowerCol = [];
    SnrCol = [];
    BerCol = [];

    for iPow = 1:numel(testPowers)
        for iConfig = 1:numel(configNames)
            commonSeed = 3000 + 100*iPow + iConfig;
            for iStep = 1:numel(stepNames)
                smf = smfBase;
                dcf = dcfBase;
                postDcf = dcfBase;

                % Maximum SSFM step for this run.
                smf.dzmax = smfDzmax(iStep);
                dcf.dzmax = dcfDzmax(iStep);
                postDcf.dzmax = dcfDzmax(iStep);
                postDcf.length = abs(Nspan*residualDispPerSpan/postDcf.disp)*1e3;

                smf.n2 = 2.5e-20;
                dcf.n2 = 2.5e-20;
                postDcf.n2 = 2.5e-20;

                rng(commonSeed);
                [snr, ber] = simulateLinkPoint(testPowers(iPow), Nspan, iConfig, ...
                    smf, dcf, postDcf, lam, symbrate, rx, pat, patbin, elec, ...
                    normFact, modfor);

                StepCol{end+1, 1} = stepNames{iStep}; %#ok<AGROW>
                ConfigCol{end+1, 1} = configNames{iConfig}; %#ok<AGROW>
                PowerCol(end+1, 1) = testPowers(iPow); %#ok<AGROW>
                SnrCol(end+1, 1) = snr; %#ok<AGROW>
                BerCol(end+1, 1) = ber; %#ok<AGROW>

                fprintf('Convergence: %s, %s, P=%+.1f dBm, SNR=%.2f dB, BER=%.3g\n', ...
                    stepNames{iStep}, configNames{iConfig}, testPowers(iPow), snr, ber);
            end
        end
    end

    convTable = table(StepCol, ConfigCol, PowerCol, SnrCol, BerCol, ...
        'VariableNames', {'StepSetting', 'Configuration', 'Power_dBm', ...
        'SNR_dB', 'BER'});
    safeWriteTable(convTable, fullfile(outDir, 'ssfm_step_convergence.csv'));

    fig = figure('Color', 'w', 'InvertHardcopy', 'off');
    tiledlayout(1, numel(testPowers));
    for iPow = 1:numel(testPowers)
        nexttile
        hold on
        for iConfig = 1:numel(configNames)
            idx = strcmp(convTable.Configuration, configNames{iConfig}) & ...
                convTable.Power_dBm == testPowers(iPow);
            plot(1:2, convTable.SNR_dB(idx), 'o-', 'LineWidth', 1.5);
        end
        grid on
        xlim([0.8 2.2])
        xticks(1:2)
        xticklabels({'coarse', 'fine'})
        ylabel('Estimated SNR [dB]')
        title(sprintf('P = %+g dBm', testPowers(iPow)))
        legend(configNames, 'Location', 'best')
        formatFigure(gca);
    end
    sgtitle(sprintf('SSFM step-size convergence, full nonlinear, N_{span} = %d', Nspan), ...
        'Color', 'k', 'FontWeight', 'bold')
    saveas(fig, fullfile(outDir, 'ssfm_step_convergence.png'));
    close(fig)
end

function plotConstellations(smfBase, dcfBase, residualDispPerSpan, spanList, ...
    lam, symbrate, rx, pat, patbin, elec, normFact, modfor, outDir)
    % Received QPSK constellations in the full nonlinear case, at one
    % launch power near the optimum and one in the strongly nonlinear regime.

    configNames = {'A: SMF-DCF', 'B: DCF-SMF'};
    % Launch powers [dBm] per span count: [near optimum, strongly nonlinear].
    % Add an entry here if spanList is changed.
    representativePowers = containers.Map('KeyType', 'double', 'ValueType', 'any');
    representativePowers(5) = [0 10];
    representativePowers(10) = [-2 10];
    representativePowers(15) = [-4 8];

    for iSpan = 1:numel(spanList)
        Nspan = spanList(iSpan);
        powers = representativePowers(Nspan);

        smf = smfBase;
        dcf = dcfBase;
        postDcf = dcfBase;
        postDcf.length = abs(Nspan*residualDispPerSpan/postDcf.disp)*1e3;

        smf.n2 = 2.5e-20;
        dcf.n2 = 2.5e-20;
        postDcf.n2 = 2.5e-20;

        fig = figure('Color', 'w', 'InvertHardcopy', 'off', 'Position', [100 100 1100 800]);
        tiledlayout(2, 2, 'TileSpacing', 'loose', 'Padding', 'compact');

        for iConfig = 1:numel(configNames)
            for iPow = 1:numel(powers)
                rng(5000 + 100*Nspan + 10*iConfig + iPow);
                [snr, ber, akhat] = simulateLinkPoint(powers(iPow), Nspan, iConfig, ...
                    smf, dcf, postDcf, lam, symbrate, rx, pat, patbin, elec, ...
                    normFact, modfor);

                nexttile
                plot(real(akhat), imag(akhat), '.', 'MarkerSize', 5)
                hold on
                % Ideal QPSK symbols as black crosses for reference.
                ideal = pat2samp((0:3).', modfor);
                plot(real(ideal), imag(ideal), 'kx', 'MarkerSize', 10, 'LineWidth', 2)
                axis equal
                axis([-2 2 -2 2])
                grid on
                xlabel('In-phase')
                ylabel('Quadrature')
                title(sprintf('%s, P=%+g dBm', configNames{iConfig}, powers(iPow)), ...
                    'FontSize', 11, 'FontWeight', 'bold')
                text(-1.85, 1.65, {sprintf('SNR = %.1f dB', snr), sprintf('BER = %.2g', ber)}, ...
                    'FontSize', 9, 'BackgroundColor', 'w', 'Margin', 2, ...
                    'EdgeColor', [0.85 0.85 0.85])
                formatFigure(gca);
            end
        end

        sgtitle(sprintf('Received QPSK constellations, full nonlinear, N_{span} = %d', Nspan), ...
            'Color', 'k', 'FontWeight', 'bold')
        saveas(fig, fullfile(outDir, sprintf('constellation_full_nonlinear_Nspan_%d.png', Nspan)));
        close(fig)
    end
end

function writtenFile = safeWriteTable(tbl, requestedFile)
    % Write a table to CSV. If the file is locked (for example, open in
    % Excel), write a time-stamped copy instead so the results are not lost.
    try
        writetable(tbl, requestedFile);
        writtenFile = requestedFile;
    catch err
        [folder, base, ext] = fileparts(requestedFile);
        fallbackFile = fullfile(folder, sprintf('%s_%s%s', base, ...
            datestr(now, 'yyyymmdd_HHMMSS'), ext));
        warning('Could not write %s (%s). Writing %s instead.', ...
            requestedFile, err.message, fallbackFile);
        writetable(tbl, fallbackFile);
        writtenFile = fallbackFile;
    end
end

function [snr, ber, akhat] = simulateLinkPoint(PdBm, Nspan, iConfig, smf, dcf, postDcf, ...
    lam, symbrate, rx, pat, patbin, elec, normFact, modfor)
    % Simulate a single operating point (one launch power, one span count,
    % one configuration). Used by the convergence test and the constellation
    % plots; it follows exactly the same chain as the main sweep.

    Plin = 10.^(PdBm/10);  % launch power [mW]
    amp.gain = smf.length*smf.alphadB*1e-3 + dcf.length*dcf.alphadB*1e-3; % span loss [dB]
    amp.f = 6;             % noise figure [dB]

    E = lasersource(Plin, lam, struct('pol', 'single'));
    E = iqmodulator(E, elec, struct('norm', normFact));

    for ns = 1:Nspan
        if iConfig == 1
            E = fiber(E, smf);
            E = fiber(E, dcf);
        else
            E = fiber(E, dcf);
            E = fiber(E, smf);
        end
        E = ampliflat(E, amp);
    end

    E = fiber(E, postDcf);

    rsig = rxfrontend(E, lam, symbrate, rx);
    akhat = rxdsp(rsig, symbrate, pat, rx);
    patbinhat = samp2pat(akhat, modfor, rx);

    snr = samp2snr(pat, akhat, modfor);
    ber = mean(patbin(:) ~= patbinhat(:));
end

function formatFigure(ax)
    % Consistent report-style formatting for every figure: white
    % background and black text, independent of the MATLAB desktop theme.
    fig = ancestor(ax, 'figure');
    if isprop(fig, 'Theme')
        fig.Theme = 'light';
    end
    ax.Color = 'w';
    ax.XColor = 'k';
    ax.YColor = 'k';
    ax.GridColor = [0.65 0.65 0.65];
    ax.MinorGridColor = [0.8 0.8 0.8];
    ax.LineWidth = 1;
    ax.FontSize = 11;
    fig.Color = 'w';
    set(findall(fig, 'Type', 'Legend'), 'Color', 'w', 'TextColor', 'k');
    set(findall(fig, 'Type', 'Text'), 'Color', 'k');
end
