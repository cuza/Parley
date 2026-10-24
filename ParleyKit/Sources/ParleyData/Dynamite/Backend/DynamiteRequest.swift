import SwiftProtobuf

/// A Dynamite RPC's request. Each carries the client's request header (its field number differs between requests),
/// which `DynamiteBackend.rpc` sets, so no request is sent without it.
protocol DynamiteRequest: SwiftProtobuf.Message {
    var requestHeader: Dynamite_RequestHeader { get set }
}

extension Dynamite_AutocompleteBotsRequest: DynamiteRequest {}
extension Dynamite_BlockEntityRequest: DynamiteRequest {}
extension Dynamite_CatchUpUserRequest: DynamiteRequest {}
extension Dynamite_ClickCardRequest: DynamiteRequest {}
extension Dynamite_CreateDmRequest: DynamiteRequest {}
extension Dynamite_CreateGroupRequest: DynamiteRequest {}
extension Dynamite_CreateMembershipRequest: DynamiteRequest {}
extension Dynamite_CreateMessageRequest: DynamiteRequest {}
extension Dynamite_CreateRosterSectionRequest: DynamiteRequest {}
extension Dynamite_CreateTopicRequest: DynamiteRequest {}
extension Dynamite_CreateUnsentMessageRequest: DynamiteRequest {}
extension Dynamite_CreateVideoCallRequest: DynamiteRequest {}
extension Dynamite_DeleteGroupRequest: DynamiteRequest {}
extension Dynamite_DeleteMessageRequest: DynamiteRequest {}
extension Dynamite_DeleteRosterSectionRequest: DynamiteRequest {}
extension Dynamite_DeleteUnsentMessageRequest: DynamiteRequest {}
extension Dynamite_EditMessageRequest: DynamiteRequest {}
extension Dynamite_GetChatBoardRequest: DynamiteRequest {}
extension Dynamite_GetGroupScopedCapabilitiesRequest: DynamiteRequest {}
extension Dynamite_GetMembersRequest: DynamiteRequest {}
extension Dynamite_GetRecurringDndRequest: DynamiteRequest {}
extension Dynamite_GetSelfUserStatusRequest: DynamiteRequest {}
extension Dynamite_GetUserPresenceRequest: DynamiteRequest {}
extension Dynamite_GroupLabelRequest: DynamiteRequest {}
extension Dynamite_HideGroupRequest: DynamiteRequest {}
extension Dynamite_InvokeDialogRequest: DynamiteRequest {}
extension Dynamite_ListAttachmentsRequest: DynamiteRequest {}
extension Dynamite_ListBlockedUsersRequest: DynamiteRequest {}
extension Dynamite_ListCustomEmojisRequest: DynamiteRequest {}
extension Dynamite_ListMembersRequest: DynamiteRequest {}
extension Dynamite_ListMessagesRequest: DynamiteRequest {}
extension Dynamite_ListReactorsRequest: DynamiteRequest {}
extension Dynamite_ListTopicsRequest: DynamiteRequest {}
extension Dynamite_ListUnsentMessagesRequest: DynamiteRequest {}
extension Dynamite_ManageBlockedRoomsRequest: DynamiteRequest {}
extension Dynamite_MarkGroupReadstateRequest: DynamiteRequest {}
extension Dynamite_MarkTopicMuteStateRequest: DynamiteRequest {}
extension Dynamite_MarkTopicReadstateRequest: DynamiteRequest {}
extension Dynamite_MessageLabelRequest: DynamiteRequest {}
extension Dynamite_PaginatedWorldRequest: DynamiteRequest {}
extension Dynamite_RemoveMembershipsRequest: DynamiteRequest {}
extension Dynamite_ReportMessageRequest: DynamiteRequest {}
extension Dynamite_SearchEmojisRequest: DynamiteRequest {}
extension Dynamite_SearchIntegrationActionsRequest: DynamiteRequest {}
extension Dynamite_SearchMessagesV2Request: DynamiteRequest {}
extension Dynamite_SearchSpaceDirectoryRequest: DynamiteRequest {}
extension Dynamite_SetCustomStatusRequest: DynamiteRequest {}
extension Dynamite_SetDndDurationRequest: DynamiteRequest {}
extension Dynamite_SetMarkAsUnreadTimestampRequest: DynamiteRequest {}
extension Dynamite_SetPresenceSharedRequest: DynamiteRequest {}
extension Dynamite_SetRecurringDndRequest: DynamiteRequest {}
extension Dynamite_SetTopicUnreadTimestampRequest: DynamiteRequest {}
extension Dynamite_SetTypingStateRequest: DynamiteRequest {}
extension Dynamite_StarGroupRequest: DynamiteRequest {}
extension Dynamite_SubmitFormActionRequest: DynamiteRequest {}
extension Dynamite_UpdateGroupRequest: DynamiteRequest {}
extension Dynamite_UpdateGroupNotificationSettingsRequest: DynamiteRequest {}
extension Dynamite_UpdateGroupRetentionSettingsRequest: DynamiteRequest {}
extension Dynamite_UpdateMembershipRoleRequest: DynamiteRequest {}
extension Dynamite_UpdateReactionRequest: DynamiteRequest {}
extension Dynamite_UpdateRosterSectionRequest: DynamiteRequest {}
extension Dynamite_UpdateUnsentMessageRequest: DynamiteRequest {}
