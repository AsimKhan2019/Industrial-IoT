// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Microsoft.Azure.IIoT.OpcUa.Registry.Tests.Deploy {
    using Autofac;
    using Autofac.Extras.Moq;
    using Microsoft.Azure.IIoT.Deploy.Runtime;
    using Microsoft.Azure.IIoT.Hub;
    using Microsoft.Azure.IIoT.Hub.Models;
    using Microsoft.Azure.IIoT.OpcUa.Registry.Deploy;
    using Microsoft.Azure.IIoT.Serializers;
    using Microsoft.Azure.IIoT.Serializers.NewtonSoft;
    using Microsoft.Extensions.Configuration;
    using Moq;
    using System.Collections.Generic;
    using System.Threading;
    using System.Threading.Tasks;
    using Xunit;

    /// <summary>
    /// Test to check layered deployments that are generated by IoTHubDiscovererDeployment
    /// </summary>
    public class IoTHubDiscovererDeploymentTests {

        [Fact]
        public async Task DiscoveryDeploymentRoutesTestAsync() {

            IList<ConfigurationModel> configurationModelList = new List<ConfigurationModel>();

            var ioTHubConfigurationServicesMock = new Mock<IIoTHubConfigurationServices>();
            ioTHubConfigurationServicesMock
                .Setup(e => e.CreateOrUpdateConfigurationAsync(It.IsAny<ConfigurationModel>(), true, CancellationToken.None))
                .Callback<ConfigurationModel, bool, CancellationToken>(
                    (confModel, forceUpdate, ct) => configurationModelList.Add(confModel))
                .Returns((ConfigurationModel configuration, bool forceUpdate, CancellationToken ct) => Task.FromResult(configuration));

            using (var mock = Setup(ioTHubConfigurationServicesMock)) {
                var discoveryDeploymentService = mock.Create<IoTHubDiscovererDeployment>();
                await discoveryDeploymentService.StartAsync();

                Assert.Equal(2, configurationModelList.Count);

                {
                    // Check routes of layered deployment for Linux
                    var configurationModel = configurationModelList[0];
                    Assert.Equal("__default-discoverer-linux", configurationModel.Id);
                    Assert.Equal(2, configurationModel.Content.ModulesContent.Count);
                    Assert.Equal("FROM /messages/modules/discovery/* INTO $upstream",
                        configurationModel.Content.ModulesContent["$edgeHub"]["properties.desired.routes.discoveryToUpstream"]);
                }
                {
                    // Check routes of layered deployment for Windows
                    var configurationModel = configurationModelList[1];
                    Assert.Equal("__default-discoverer-windows", configurationModel.Id);
                    Assert.Equal(2, configurationModel.Content.ModulesContent.Count);
                    Assert.Equal("FROM /messages/modules/discovery/* INTO $upstream",
                        configurationModel.Content.ModulesContent["$edgeHub"]["properties.desired.routes.discoveryToUpstream"]);
                }
            }
        }

        [Fact]
        public async Task ContainerRegistryConfigTestAsync() {

            IList<ConfigurationModel> configurationModelList = new List<ConfigurationModel>();

            var ioTHubConfigurationServicesMock = new Mock<IIoTHubConfigurationServices>();
            ioTHubConfigurationServicesMock
                .Setup(e => e.CreateOrUpdateConfigurationAsync(It.IsAny<ConfigurationModel>(), true, CancellationToken.None))
                .Callback<ConfigurationModel, bool, CancellationToken>(
                    (confModel, forceUpdate, ct) => configurationModelList.Add(confModel))
                .Returns((ConfigurationModel configuration, bool forceUpdate, CancellationToken ct) => Task.FromResult(configuration));

            var configuration = new ConfigurationBuilder()
                .AddInMemoryCollection()
                .Build();
            configuration["Docker:Server"] = "custom.azurecr.io";
            configuration["Docker:User"] = "dUser";
            configuration["Docker:Password"] = "dPassword";
            configuration["Docker:ImagesNamespace"] = "customNamespace";
            configuration["Docker:ImagesTag"] = "4.5.6.7";

            using (var mock = Setup(ioTHubConfigurationServicesMock, configuration)) {
                var discoveryDeploymentService = mock.Create<IoTHubDiscovererDeployment>();
                var jsonserializer = mock.Container.Resolve<IJsonSerializer>();

                await discoveryDeploymentService.StartAsync();

                Assert.Equal(2, configurationModelList.Count);

                {
                    // Check details of docker image in layered deployment for Linux
                    var configurationModel = configurationModelList[0];
                    Assert.Equal("__default-discoverer-linux", configurationModel.Id);
                    Assert.Equal(2, configurationModel.Content.ModulesContent.Count);

                    var registryCredentials = (Newtonsoft.Json.Linq.JObject)configurationModel.Content.ModulesContent["$edgeAgent"]["properties.desired.runtime.settings.registryCredentials.custom"];
                    Assert.Equal("custom.azurecr.io", registryCredentials.Value<string>("address"));
                    Assert.Equal("dPassword", registryCredentials.Value<string>("password"));
                    Assert.Equal("dUser", registryCredentials.Value<string>("username"));

                    var module = (Newtonsoft.Json.Linq.JObject)configurationModel.Content.ModulesContent["$edgeAgent"]["properties.desired.modules.discovery"];
                    Assert.Equal("custom.azurecr.io/customNamespace/iotedge/discovery:4.5.6.7",
                        module["settings"].Value<string>("image"));
                }
                {
                    // Check details of docker image in layered deployment for Windows
                    var configurationModel = configurationModelList[1];
                    Assert.Equal("__default-discoverer-windows", configurationModel.Id);
                    Assert.Equal(2, configurationModel.Content.ModulesContent.Count);

                    var registryCredentials = (Newtonsoft.Json.Linq.JObject)configurationModel.Content.ModulesContent["$edgeAgent"]["properties.desired.runtime.settings.registryCredentials.custom"];
                    Assert.Equal("custom.azurecr.io", registryCredentials.Value<string>("address"));
                    Assert.Equal("dPassword", registryCredentials.Value<string>("password"));
                    Assert.Equal("dUser", registryCredentials.Value<string>("username"));

                    var module = (Newtonsoft.Json.Linq.JObject)configurationModel.Content.ModulesContent["$edgeAgent"]["properties.desired.modules.discovery"];
                    Assert.Equal("custom.azurecr.io/customNamespace/iotedge/discovery:4.5.6.7",
                        module["settings"].Value<string>("image"));
                }
            }
        }

        /// <summary>
        /// Setup mock
        /// </summary>
        /// <param name="ioTHubConfigurationServicesMock"></param>
        /// <param name="configuration"></param>
        private static AutoMock Setup(
            Mock<IIoTHubConfigurationServices> ioTHubConfigurationServicesMock = null,
            IConfiguration configuration = null
        ) {
            var mock = AutoMock.GetLoose(builder => {
                // Use empty configuration root if one is not passed.
                var conf = configuration ?? new ConfigurationBuilder()
                    .AddInMemoryCollection()
                    .Build();

                // Setup configuration
                builder.RegisterInstance(conf)
                    .As<IConfiguration>()
                    .SingleInstance();

                var containerRegistryConfig = new ContainerRegistryConfig(conf);
                builder.RegisterInstance(containerRegistryConfig)
                    .AsImplementedInterfaces()
                    .SingleInstance();

                // Setup JSON serializer
                builder.RegisterType<NewtonSoftJsonConverters>()
                    .As<IJsonSerializerConverterProvider>();
                builder.RegisterType<NewtonSoftJsonSerializer>()
                    .As<IJsonSerializer>();

                // Setup IIoTHubConfigurationServices mock
                if (ioTHubConfigurationServicesMock is null) {
                    var ioTHubConfigurationServices = new Mock<IIoTHubConfigurationServices>();
                    ioTHubConfigurationServices
                        .Setup(e => e.CreateOrUpdateConfigurationAsync(It.IsAny<ConfigurationModel>(), true, CancellationToken.None))
                        .Returns((ConfigurationModel configuration, bool forceUpdate, CancellationToken ct) => Task.FromResult(configuration));
                    builder.RegisterMock(ioTHubConfigurationServices);
                }
                else {
                    builder.RegisterMock(ioTHubConfigurationServicesMock);
                }

                builder.RegisterType<IoTHubDiscovererDeployment>()
                    .AsSelf(); ;
            });
            return mock;
        }
    }
}
