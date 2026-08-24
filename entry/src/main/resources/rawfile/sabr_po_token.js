/* Port of PipePipe 5.3.0 assets/sabr_po_token.js, adapted to the
 * runJavaScript-polling bridge (window.__yourpipeSabr) instead of the
 * PipePipeWebViewBridge JavascriptInterface.
 *
 * Critical: BotGuard must run with window.yt.config_.EVENT_ID set to the
 * home page session's EVENT_ID, because YouTube binds the embedded initial
 * attestation challenge (window.ytAtN) to it. Tokens minted without this
 * binding are rejected by SABR at the ~60s boundary (status 2 -> 3).
 */
(function () {
  var root = window;
  root.__yourpipeSabr = { status: 'helper-ready', error: '', botguardResponse: '' };

  function loadBotGuard(state, challengeData, onReady, onError) {
    var intervalId;
    var finished = false;

    function fail(error) {
      if (finished) {
        return;
      }
      finished = true;
      if (intervalId) {
        clearInterval(intervalId);
      }
      onError(error);
    }

    try {
      var vm = root[challengeData.globalName];
      var program = challengeData.program;
      var vmFunctions = {};

      if (!vm) {
        throw new Error('[BotGuardClient]: VM not found in the global object');
      }
      if (!vm.a) {
        throw new Error('[BotGuardClient]: Could not load program');
      }

      var vmFunctionsCallback = function (
        asyncSnapshotFunction,
        shutdownFunction,
        passEventFunction,
        checkCameraFunction
      ) {
        vmFunctions = {
          asyncSnapshotFunction: asyncSnapshotFunction,
          shutdownFunction: shutdownFunction,
          passEventFunction: passEventFunction,
          checkCameraFunction: checkCameraFunction
        };
      };

      var noOp = function () {};
      var loggerFunctions = [noOp, noOp, noOp, noOp, noOp];
      var interactionElement = document.getElementById('interaction') || document.body;

      state.syncSnapshotFunction = vm.a(
        program,
        vmFunctionsCallback,
        true,
        interactionElement,
        noOp,
        [[], []],
        undefined,
        false,
        loggerFunctions
      )[0];

      var polls = 0;
      intervalId = setInterval(function () {
        if (vmFunctions.asyncSnapshotFunction) {
          finished = true;
          clearInterval(intervalId);
          onReady(vmFunctions);
          return;
        }
        if (polls >= 10000) {
          fail(new Error('asyncSnapshotFunction is null even after 10 seconds'));
          return;
        }
        polls++;
      }, 1);
    } catch (error) {
      fail(error);
    }
  }

  function snapshot(vmFunctions, webPoSignalOutput, onSuccess, onError) {
    try {
      if (!vmFunctions.asyncSnapshotFunction) {
        throw new Error('[BotGuardClient]: Async snapshot function not found');
      }
      vmFunctions.asyncSnapshotFunction(
        function (response) {
          onSuccess(response);
        },
        [undefined, undefined, webPoSignalOutput, undefined]
      );
    } catch (error) {
      onError(error);
    }
  }

  root.yourpipeRunBotGuard = function (eventId, challengeData) {
    var state = root.__yourpipeSabr;
    state.status = 'botguard-loading';
    try {
      root.yt = root.yt || {};
      root.yt.config_ = root.yt.config_ || {};
      root.yt.config_.EVENT_ID = eventId;

      var interpreterJavascript =
        challengeData.interpreterJavascript &&
        challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
      if (!interpreterJavascript) {
        throw new Error('Could not load VM');
      }
      new Function(interpreterJavascript)();

      var webPoSignalOutput = [];
      loadBotGuard(
        state,
        {
          globalName: challengeData.globalName,
          program: challengeData.program
        },
        function (vmFunctions) {
          snapshot(
            vmFunctions,
            webPoSignalOutput,
            function (botguardResponse) {
              state.signalOutput = webPoSignalOutput;
              state.botguardResponse = botguardResponse;
              state.status = 'botguard-ready';
            },
            function (error) {
              state.error = String(error) + '\n' + (error && error.stack ? error.stack : '');
              state.status = 'error';
            }
          );
        },
        function (error) {
          state.error = String(error) + '\n' + (error && error.stack ? error.stack : '');
          state.status = 'error';
        }
      );
    } catch (error) {
      state.error = String(error) + '\n' + (error && error.stack ? error.stack : '');
      state.status = 'error';
    }
  };

  root.yourpipeCreateMinter = function (integrityToken) {
    var state = root.__yourpipeSabr;
    try {
      var getMinter = state.signalOutput && state.signalOutput[0];
      if (!getMinter) throw new Error('PMD:Undefined');
      state.minter = getMinter(integrityToken);
      if (!(state.minter instanceof Function)) throw new Error('APF:Failed');
      state.status = 'minter-ready';
      return 'minter-ready';
    } catch (e) {
      state.error = String(e && e.stack ? e.stack : e);
      state.status = 'error';
      return 'error:' + state.error;
    }
  };

  root.yourpipeMintPoToken = function (identifier) {
    var state = root.__yourpipeSabr;
    try {
      if (!state.minter) throw new Error('Local DOM PO token minter is not ready');
      var bytes = new TextEncoder().encode(identifier);
      var token = state.minter(bytes);
      if (!token) throw new Error('YNJ:Undefined');
      if (!(token instanceof Uint8Array)) throw new Error('ODM:Invalid');
      return Array.prototype.join.call(token, ',');
    } catch (e) {
      state.error = String(e && e.stack ? e.stack : e);
      state.status = 'error';
      return '';
    }
  };
})();
