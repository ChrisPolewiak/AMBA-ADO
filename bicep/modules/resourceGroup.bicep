targetScope = 'subscription'

@description('Name of the resource group to be created.')
param param_name string

@description('Location for the resource group.')
param param_location string

@description('Lock configuration for the resource group. Fields: lockLevel, notes.')
param param_lock object = {}

@description('Azure tags to be applied to all resources deployed in this module.')
param param_tags object = {}

// Module for deploying the resource group
module module_resourceGroup 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'deploy-${param_name}-${param_location}'
  params: {
    name: param_name

    location: param_location
    lock: param_lock
    tags: param_tags
  }
}
