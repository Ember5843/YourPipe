export class SubscriptionUser {
  channelId: string;
  displayName: string;
  avatarUrl: string;
  subscriberText: string;
  videoCountText: string;
  description: string;
  thumbnailColor: string;

  constructor(
    channelId: string,
    displayName: string,
    avatarUrl: string = '',
    subscriberText: string = '',
    videoCountText: string = '',
    description: string = '',
    thumbnailColor: string = ''
  ) {
    this.channelId = channelId;
    this.displayName = displayName;
    this.avatarUrl = avatarUrl;
    this.subscriberText = subscriberText;
    this.videoCountText = videoCountText;
    this.description = description;
    this.thumbnailColor = thumbnailColor;
  }
}
