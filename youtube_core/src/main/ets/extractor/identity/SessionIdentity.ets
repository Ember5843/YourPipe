/**
 * Playback session identity. YouTube web keeps ONE visitorData per visit and
 * mints every PoToken against it; the identity groups that visitorData with
 * the client it was captured on and (later stages) the player PoToken bound
 * to it.
 *
 * Stage 0: only `visitorData` is wired (pinned from the prewarmed watch page
 * or the first player response). clientName/clientVersion/playerPoToken are
 * reserved for identity rotation and player-request token injection.
 */
export interface SessionIdentity {
  visitorData: string;
  clientName: string;
  clientVersion: string;
  playerPoToken?: string;
}
