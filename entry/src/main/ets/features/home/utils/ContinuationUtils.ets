interface ContinuationCommand {
  token?: string;
}

interface ContinuationEndpoint {
  continuationCommand?: ContinuationCommand;
}

interface ContinuationItemRenderer {
  continuationEndpoint?: ContinuationEndpoint;
}

export function getContinuationToken(renderer?: ContinuationItemRenderer): string | null {
  const token = renderer?.continuationEndpoint?.continuationCommand?.token;
  if (!token || token.length === 0) {
    return null;
  }
  return token;
}

export function getContinuationTokenFromContents(sectionContents: Array<Record<string, Object>>): string | null {
  for (const entry of sectionContents) {
    const renderer = entry["continuationItemRenderer"] as ContinuationItemRenderer;
    const token = getContinuationToken(renderer);
    if (token) {
      return token;
    }
  }
  return null;
}

export function getPlaylistContinuationToken(renderer: Record<string, Object> | undefined): string | null {
  if (!renderer) return null;

  // Classic: continuationItemRenderer.continuationEndpoint...
  const endpoint = renderer["continuationEndpoint"] as Record<string, Object>;
  if (endpoint) {
    const commandExecutor = endpoint["commandExecutorCommand"] as Record<string, Object>;
    if (commandExecutor) {
      const commands = commandExecutor["commands"] as Array<Record<string, Object>>;
      if (commands && commands.length > 0) {
        for (const command of commands) {
          const continuationCommand = command["continuationCommand"] as Record<string, Object>;
          const token = continuationCommand ? (continuationCommand["token"] as string) : "";
          if (token) return token;
        }
      }
    }
    const continuationCommand = endpoint["continuationCommand"] as Record<string, Object>;
    const token = continuationCommand ? (continuationCommand["token"] as string) : "";
    if (token) return token;
  }

  // Modern: continuationItemViewModel.continuationCommand.innertubeCommand.continuationCommand.token
  // (PipePipe YoutubePlaylistExtractor.getNextPageFrom)
  const viewModel = renderer["continuationItemViewModel"] as Record<string, Object>;
  if (viewModel) {
    const contCmd = viewModel["continuationCommand"] as Record<string, Object>;
    const innertube = contCmd ? (contCmd["innertubeCommand"] as Record<string, Object>) : undefined;
    const nested = innertube ? (innertube["continuationCommand"] as Record<string, Object>) : undefined;
    const token = nested ? (nested["token"] as string) : "";
    if (token) return token;
  }

  // Content item may itself be the view-model root.
  const contCmd = renderer["continuationCommand"] as Record<string, Object>;
  if (contCmd) {
    const innertube = contCmd["innertubeCommand"] as Record<string, Object>;
    const nested = innertube
      ? (innertube["continuationCommand"] as Record<string, Object>)
      : (contCmd["continuationCommand"] as Record<string, Object>) || contCmd;
    const token = nested ? (nested["token"] as string) : "";
    if (token) return token;
  }

  return null;
}

export function getMusicContinuationToken(continuations: Array<Record<string, Object>> | undefined): string | null {
  if (!continuations || continuations.length === 0) return null;
  const first = continuations[0] as Record<string, Object>;
  const nextData = first ? (first["nextContinuationData"] as Record<string, Object>) : undefined;
  const token = nextData ? (nextData["continuation"] as string) : "";
  return token || null;
}
