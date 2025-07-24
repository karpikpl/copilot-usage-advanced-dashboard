@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}

param cpuAdUpdaterExists bool
@secure()
param cpuAdUpdaterDefinition object

param updateGrafanaExists bool
@secure()
param updateGrafanaDefinition object

param elasticSearchExists bool
@secure()
param elasticSearchDefinition object

param grafanaExists bool
@secure()
param grafanaDefinition object

@description('Id of the user or app to assign application roles')
param principalId string?

@secure()
param grafanaUsername string

@secure()
param grafanaPassword string

@secure()
param githubPat string
param githubOrganizationSlugs string

param elasticSearchImageName string
param grafanaImageName string

param doRoleAssignments bool = true

param authentication object

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)
var elasticSearchFileShareName = 'elastic-search'
var grafanaFileShareName = 'grafana'
var cpuadUpdaterFileShareName = 'cpuad-updater'

var grafanaUsernameSecretName = 'grafana-username'
var grafanaUsernameSecretValue = grafanaUsername != ''
  ? grafanaUsername
  : uniqueString('grafanaUsername', subscription().id, resourceGroup().id, location, resourceToken)
var grafanaUsernameSecretFilename = 'admin_user'
var grafanaPasswordSecretName = 'grafana-password'
var grafanaPasswordSecretValue = grafanaPassword != ''
  ? grafanaPassword
  : uniqueString('grafanaPassword', subscription().id, resourceGroup().id, location, resourceToken)
var grafanaPasswordSecretFilename = 'admin_password'
var githubPatSecretName = 'github-pat'
var managedIdentityClientIdSecretName = 'override-use-mi-fic-assertion-client-id'

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoringDeployment'
  params: {
    location: location
    tags: tags
    abbrs: abbrs
    resourceToken: resourceToken
  }
}

module identity './modules/user-assigned-managed-identity.bicep' = {
  name: 'identityDeployment'
  params: {
    location: location
    abbrs: abbrs
    resourceToken: resourceToken
  }
}

module containerRegistry './modules/container-registry.bicep' = {
  name: 'containerRegistryDeployment'
  params: {
    location: location
    tags: tags
    abbrs: abbrs
    resourceToken: resourceToken
    principalId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID
    doRoleAssignments: doRoleAssignments
  }
}

module keyVault './modules/key-vault.bicep' = {
  name: 'keyVaultDeployment'
  params: {
    location: location
    abbrs: abbrs
    resourceToken: resourceToken
    tags: tags
    userAssignedManagedIdentityPrincipalId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID
    principalId: principalId
    doRoleAssignments: doRoleAssignments
    secrets: [
      {
        name: grafanaUsernameSecretName
        value: grafanaUsernameSecretValue
      }
      {
        name: grafanaPasswordSecretName
        value: grafanaPasswordSecretValue
      }
      {
        name: githubPatSecretName
        value: githubPat
      }
      {
        name: managedIdentityClientIdSecretName
        value: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_CLIENT_ID
      }
    ]
  }
}

module virtualNetwork './modules/virtual-network.bicep' = {
  name: 'virtualNetworkDeployment'
  params: {
    location: location
    abbrs: abbrs
    resourceToken: resourceToken
  }
}

module storageAccount './modules/storage-account.bicep' = {
  name: 'storageAccountDeployment'
  params: {
    location: location
    tags: tags
    abbrs: abbrs
    resourceToken: resourceToken
    elasticSearchFileShareName: elasticSearchFileShareName
    grafanaFileShareName: grafanaFileShareName
    cpuadUpdaterFileShareName: cpuadUpdaterFileShareName
    userAssignedIdentityPrincipalId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID
    keyVaultResourceId: keyVault.outputs.AZURE_RESOURCE_KEY_VAULT_ID
    containerAppsVirtualNetworkId: virtualNetwork.outputs.AZURE_VIRTUAL_NETWORK_CONTAINER_APPS_SUBNET_ID
    doRoleAssignments: doRoleAssignments
  }
}

module containerAppsEnvironment './modules/container-app-environment.bicep' = {
  name: 'containerAppsEnvironmentDeployment'
  params: {
    location: location
    abbrs: abbrs
    workloadProfileType: 'D8'
    resourceToken: resourceToken
    logAnalyticsWorkspaceResourceId: monitoring.outputs.AZURE_RESOURCE_MONITORING_LOG_ANALYTICS_ID
    infrastructureSubnetId: virtualNetwork.outputs.AZURE_VIRTUAL_NETWORK_CONTAINER_APPS_SUBNET_ID
    storages: [
      {
        kind: 'NFS'
        accessMode: 'ReadWrite'
        shareName: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
        storageAccountName: storageAccount.outputs.AZURE_STORAGE_ACCOUNT_NAME
      }
      {
        kind: 'NFS'
        accessMode: 'ReadWrite'
        shareName: storageAccount.outputs.AZURE_STORAGE_GRAFANA_FILE_SHARE_NAME
        storageAccountName: storageAccount.outputs.AZURE_STORAGE_ACCOUNT_NAME
      }
      {
        kind: 'NFS'
        accessMode: 'ReadWrite'
        shareName: storageAccount.outputs.AZURE_STORAGE_CPUAD_UPDATER_FILE_SHARE_NAME
        storageAccountName: storageAccount.outputs.AZURE_STORAGE_ACCOUNT_NAME
      }
    ]
    publicNetworkAccess: 'Enabled'
    appInsightsConnectionString: monitoring.outputs.AZURE_RESOURCE_MONITORING_APP_INSIGHTS_CONNECTION_STRING
  }
}

module cpuadUpdaterFetchLatestImage './modules/fetch-container-job-image.bicep' = {
  name: 'cpuadUpdaterFetchImageDeployment'
  params: {
    exists: cpuAdUpdaterExists
    name: 'cpuad-updater'
  }
}

var additionalCpuadUpdaterDefinition = {
  settings: union(
    [
      {
        name: 'GITHUB_PAT'
        keyVaultSecretName: githubPatSecretName
        secret: true
      }
      {
        name: 'ORGANIZATION_SLUGS'
        value: githubOrganizationSlugs
      }
    ],
    cpuAdUpdaterDefinition.settings
  )
}

module cpuadUpdater './modules/container-job.bicep' = {
  name: 'cpuadUpdaterDeployment'
  params: {
    name: 'cpuad-updater'
    location: location
    workloadProfileName: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_WORKLOAD_PROFILE_CONSUMPTION
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_ENVIRONMENT_ID
    applicationInsightsConnectionString: monitoring.outputs.AZURE_RESOURCE_MONITORING_APP_INSIGHTS_CONNECTION_STRING
    definition: additionalCpuadUpdaterDefinition
    fetchLatestImage: cpuadUpdaterFetchLatestImage
    userAssignedManagedIdentityResourceId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_ID
    userAssignedManagedIdentityClientId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_CLIENT_ID
    tags: tags
    cpu: cpuAdUpdaterDefinition.cpu
    memory: cpuAdUpdaterDefinition.memory
    volumeMounts: [
      {
        mountPath: '/app/logs'
        volumeName: storageAccount.outputs.AZURE_STORAGE_CPUAD_UPDATER_FILE_SHARE_NAME
      }
    ]
    volumes: [
      {
        name: storageAccount.outputs.AZURE_STORAGE_CPUAD_UPDATER_FILE_SHARE_NAME
        storageName: storageAccount.outputs.AZURE_STORAGE_CPUAD_UPDATER_FILE_SHARE_NAME
        storageType: 'NfsAzureFile'
        mountOptions: 'dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks,nobrl,cache=none'
      }
    ]
    cronExpression: cpuAdUpdaterDefinition.cronExpression
    triggerType: cpuAdUpdaterDefinition.triggerType
    keyVaultName: keyVault.outputs.AZURE_RESOURCE_KEY_VAULT_NAME
  }
}

module updateGrafanaFetchLatestImage './modules/fetch-container-job-image.bicep' = {
  name: 'updateGrafanaFetchImageDeployment'
  params: {
    exists: updateGrafanaExists
    name: 'update-grafana'
  }
}

var additionalUpdateGrafanaDefinition = {
  settings: union(
    [
      {
        name: 'GRAFANA_USERNAME'
        keyVaultSecretName: grafanaUsernameSecretName
        secret: true
      }
      {
        name: 'GRAFANA_PASSWORD'
        keyVaultSecretName: grafanaPasswordSecretName
        secret: true
      }
    ],
    updateGrafanaDefinition.settings
  )
}

module updateGrafana './modules/container-job.bicep' = {
  name: 'updateGrafanaDeployment'
  params: {
    name: 'update-grafana'
    location: location
    workloadProfileName: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_WORKLOAD_PROFILE_CONSUMPTION
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_ENVIRONMENT_ID
    applicationInsightsConnectionString: monitoring.outputs.AZURE_RESOURCE_MONITORING_APP_INSIGHTS_CONNECTION_STRING
    definition: additionalUpdateGrafanaDefinition
    fetchLatestImage: updateGrafanaFetchLatestImage
    userAssignedManagedIdentityResourceId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_ID
    userAssignedManagedIdentityClientId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_CLIENT_ID
    tags: tags
    cpu: updateGrafanaDefinition.cpu
    memory: updateGrafanaDefinition.memory
    triggerType: updateGrafanaDefinition.triggerType
    keyVaultName: keyVault.outputs.AZURE_RESOURCE_KEY_VAULT_NAME
  }
}

module elasticSearchFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'elasticSearchFetchImageDeployment'
  params: {
    exists: elasticSearchExists
    name: 'elastic-search'
  }
}

var elasticSearchPort = 9200

module elasticSearch './modules/container-app.bicep' = {
  name: 'elasticSearchDeployment'
  params: {
    name: 'elastic-search'
    location: location
    workloadProfileName: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_ENVIRONMENT_ID
    applicationInsightsConnectionString: monitoring.outputs.AZURE_RESOURCE_MONITORING_APP_INSIGHTS_CONNECTION_STRING
    definition: elasticSearchDefinition
    existingImage: elasticSearchImageName
    ingressTargetPort: elasticSearchPort
    userAssignedManagedIdentityResourceId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_ID
    userAssignedManagedIdentityClientId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_CLIENT_ID
    tags: tags
    cpu: elasticSearchDefinition.cpu
    memory: elasticSearchDefinition.memory
    scaleMaxReplicas: 1
    volumeMounts: [
      {
        mountPath: '/usr/share/elasticsearch/data'
        volumeName: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
        subPath: 'data'
      }
      {
        mountPath: '/usr/share/elasticsearch/logs'
        volumeName: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
        subPath: 'logs'
      }
    ]
    volumes: [
      {
        name: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
        storageName: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
        storageType: 'NfsAzureFile'
        mountOptions: 'dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks,nobrl,cache=none'
      }
    ]
    ingressExternal: false
    keyVaultName: keyVault.outputs.AZURE_RESOURCE_KEY_VAULT_NAME
    initContainersTemplate: [
      {
        name: 'init-elasticsearch'
        image: 'busybox:1.28'
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        command: [
          '/bin/sh'
        ]
        args: [
          '-c'
          'chown -R 1000:1000 /usr/share/elasticsearch/data && chown -R 1000:1000 /usr/share/elasticsearch/logs'
        ]
        volumeMounts: [
          {
            mountPath: '/usr/share/elasticsearch/data'
            volumeName: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
            subPath: 'data'
          }
          {
            mountPath: '/usr/share/elasticsearch/logs'
            volumeName: storageAccount.outputs.AZURE_STORAGE_ELASTIC_SEARCH_FILE_SHARE_NAME
            subPath: 'logs'
          }
        ]
      }
    ]
    // probes: [
    //   {
    //     type: 'Liveness'
    //     httpGet: {
    //       path: '/_cluster/health?wait_for_status=yellow&timeout=50s'
    //       port: elasticSearchPort
    //     }
    //     initialDelaySeconds: 10
    //     periodSeconds: 10
    //     failureThreshold: 10
    //   }
    //   {
    //     type: 'Readiness'
    //     httpGet: {
    //       path: '/_cluster/health?wait_for_status=yellow&timeout=50s'
    //       port: elasticSearchPort
    //     }
    //     initialDelaySeconds: 10
    //     periodSeconds: 10
    //     failureThreshold: 10
    //   }
    //   {
    //     type: 'Startup'
    //     httpGet: {
    //       path: '/_cluster/health?wait_for_status=yellow&timeout=50s'
    //       port: elasticSearchPort
    //     }
    //     initialDelaySeconds: 10
    //     periodSeconds: 10
    //     failureThreshold: 10
    //   }
    // ]
  }
}

module grafanaFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'grafanaFetchImageDeployment'
  params: {
    exists: grafanaExists
    name: 'grafana'
  }
}

var additionalGrafanaDefinition = {
  settings: union(
    [
      {
        name: 'GRAFANA_USERNAME'
        keyVaultSecretName: grafanaUsernameSecretName
        secret: true
        path: grafanaUsernameSecretFilename
      }
      {
        name: 'GRAFANA_PASSWORD'
        keyVaultSecretName: grafanaPasswordSecretName
        secret: true
        path: grafanaPasswordSecretFilename
      }
      {
        name: 'GF_SECURITY_ADMIN_USER__FILE'
        value: '/run/secrets/${grafanaUsernameSecretFilename}'
      }
      {
        name: 'GF_SECURITY_ADMIN_PASSWORD__FILE'
        value: '/run/secrets/${grafanaPasswordSecretFilename}'
      }
      {
        name: 'GF_AUTH_PROXY_ENABLED'
        value: bool(authentication.enabled) ? 'true' : 'false'
      }
      {
        name: 'GF_AUTH_PROXY_HEADER_NAME'
        value: 'X-MS-CLIENT-PRINCIPAL-NAME'
      }
      {
        name: 'GF_AUTH_PROXY_HEADER_PROPERTY'
        value: 'email'
      }
      {
        name: managedIdentityClientIdSecretName
        keyVaultSecretName: managedIdentityClientIdSecretName
        secret: true
        path: managedIdentityClientIdSecretName
      }
    ],
    grafanaDefinition.settings
  )
}

var grafanaPort = 80

module grafana './modules/container-app.bicep' = {
  name: 'grafanaDeployment'
  params: {
    name: 'grafana'
    location: location
    workloadProfileName: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_WORKLOAD_PROFILE_CONSUMPTION
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_ENVIRONMENT_ID
    applicationInsightsConnectionString: monitoring.outputs.AZURE_RESOURCE_MONITORING_APP_INSIGHTS_CONNECTION_STRING
    definition: additionalGrafanaDefinition
    ingressTargetPort: grafanaPort
    existingImage: grafanaImageName
    userAssignedManagedIdentityResourceId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_ID
    userAssignedManagedIdentityClientId: identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_CLIENT_ID
    tags: tags
    ingressExternal: true
    cpu: grafanaDefinition.cpu
    memory: grafanaDefinition.memory
    scaleMaxReplicas: 1
    volumeMounts: [
      {
        mountPath: '/var/lib/grafana'
        volumeName: storageAccount.outputs.AZURE_STORAGE_GRAFANA_FILE_SHARE_NAME
      }
    ]
    volumes: [
      {
        name: storageAccount.outputs.AZURE_STORAGE_GRAFANA_FILE_SHARE_NAME
        storageName: storageAccount.outputs.AZURE_STORAGE_GRAFANA_FILE_SHARE_NAME
        storageType: 'NfsAzureFile'
        mountOptions: 'dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks,nobrl,cache=none'
      }
    ]
    keyVaultName: keyVault.outputs.AZURE_RESOURCE_KEY_VAULT_NAME
    authentication: authentication
    managedIdentityClientIdSecretName: managedIdentityClientIdSecretName
    // probes: [
    //   {
    //     type: 'Liveness'
    //     httpGet: {
    //       path: '/api/health'
    //       port: grafanaPort
    //     }
    //     initialDelaySeconds: 10
    //     periodSeconds: 10
    //     failureThreshold: 10
    //   }
    //   {
    //     type: 'Readiness'
    //     httpGet: {
    //       path: '/api/health'
    //       port: grafanaPort
    //     }
    //     initialDelaySeconds: 10
    //     periodSeconds: 10
    //     failureThreshold: 10
    //   }
    //   {
    //     type: 'Startup'
    //     httpGet: {
    //       path: '/api/health'
    //       port: grafanaPort
    //     }
    //     initialDelaySeconds: 10
    //     periodSeconds: 10
    //     failureThreshold: 10
    //   }
    // ]
  }
}

output AZURE_RESOURCE_UPDATE_GRAFANA_ID string = updateGrafana.outputs.AZURE_RESOURCE_CONTAINER_APP_ID
output AZURE_RESOURCE_UPDATE_GRAFANA_NAME string = updateGrafana.outputs.AZURE_RESOURCE_CONTAINER_APP_NAME
output AZURE_RESOURCE_CPUAD_UPDATER_ID string = cpuadUpdater.outputs.AZURE_RESOURCE_CONTAINER_APP_ID
output AZURE_RESOURCE_CPUAD_UPDATER_NAME string = cpuadUpdater.outputs.AZURE_RESOURCE_CONTAINER_APP_NAME
output AZURE_RESOURCE_ELASTIC_SEARCH_ID string = elasticSearch.outputs.AZURE_RESOURCE_CONTAINER_APP_ID
output AZURE_RESOURCE_GRAFANA_ID string = grafana.outputs.AZURE_RESOURCE_CONTAINER_APP_ID
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = containerAppsEnvironment.outputs.AZURE_RESOURCE_CONTAINER_APPS_ENVIRONMENT_NAME
output AZURE_CONTAINER_REGISTRY_LOGIN_SERVER string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_NAME
output SERVICE_UPDATEGRAFANA_RESOURCE_EXISTS bool = true
output SERVICE_CPUADUPDATER_RESOURCE_EXISTS bool = true
output GRAFANA_DASHBOARD_URL string = grafana.outputs.AZURE_RESOURCE_CONTAINER_APP_FQDN
output GRAFANA_DASHBOARD_AUTHENTICATION_CALLBACK_URI string = grafana.outputs.AZURE_RESOURCE_CONTAINER_APP_AUTHENTICATION_CALLBACK_URI
output MANAGED_IDENTITY_NAME string = identity.outputs.AZURE_RESOURCE_USER_ASSIGNED_IDENTITY_NAME
