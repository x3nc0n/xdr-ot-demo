using '../main.bicep'

param location = 'eastus2'
param prefix = 'otlab'
param adminUsername = 'labadmin'
// Inject these environment variables at build/deployment time; never store the resulting secure parameters file.
param adminPassword = readEnvironmentVariable('OTLAB_ADMIN_PASSWORD')
param linuxSshPublicKey = readEnvironmentVariable('OTLAB_SSH_PUBLIC_KEY')
param budgetEmails = []
