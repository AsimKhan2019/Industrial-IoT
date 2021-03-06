// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Microsoft.Azure.IIoT.Services.OpcUa.Events {
    using Microsoft.Azure.IIoT.Services.OpcUa.Events.Auth;
    using Microsoft.Azure.IIoT.Messaging.SignalR;
    using Microsoft.AspNetCore.SignalR;
    using Microsoft.AspNetCore.Authorization;

    /// <summary>
    /// Gateway hub
    /// </summary>
    [Route("v2/gateways/events")]
    [Authorize(Policy = Policies.CanRead)]
    public class GatewaysHub : Hub {

    }
}