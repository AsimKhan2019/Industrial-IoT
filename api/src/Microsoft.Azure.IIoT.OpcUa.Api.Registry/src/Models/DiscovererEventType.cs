// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Microsoft.Azure.IIoT.OpcUa.Api.Registry.Models {
    using System.Runtime.Serialization;

    /// <summary>
    /// Discoverer event type
    /// </summary>
    [DataContract]
    public enum DiscovererEventType {

        /// <summary>
        /// New
        /// </summary>
        [EnumMember]
        New,

        /// <summary>
        /// Updated
        /// </summary>
        [EnumMember]
        Updated,

        /// <summary>
        /// Deleted
        /// </summary>
        [EnumMember]
        Deleted,
    }
}