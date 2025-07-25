#steps from https://learn.microsoft.com/en-us/azure/dev-box/how-to-customize-devbox-azure-image-builder

## References:
# https://github.com/luxu-ms/Devbox-ADE-Infra/tree/devbox-ade-openai
# https://github.com/gbordier/devbox-demo
# https://github.com/berkanuslu/choco-development-enviroment-setup/blob/8dfb4e3947216943e668f08477a3f0b2152f2f38/setup_development_environment.ps1#L16


# move to folder customImage
Set-Location -Path customImage

'Az.ImageBuilder', 'Az.ManagedServiceIdentity' | ForEach-Object {Install-Module -Name $_ -AllowPrerelease}

Connect-AzAccount

# Get existing context 
$currentAzContext = Get-AzContext

# Get your current subscription ID  
$subscriptionID=$currentAzContext.Subscription.Id

# Destination image resource group  
$imageResourceGroup="rg-demo-devbox"

# Location  
$location="uksouth"

# Image distribution metadata reference name  
$runOutputName="aibCustWinManImg01"

# Set up role definition names, which need to be unique 
$timeInt=$(get-date -UFormat "%s") 
$imageRoleDefName="Azure Image Builder Image Def"+$timeInt 
$identityName="aibIdentity"+$timeInt


# Create an identity 
New-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName -Location $location

$identityNameResourceId=$(Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName).Id 
$identityNamePrincipalId=$(Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName).PrincipalId

$aibRoleImageCreationUrl="https://raw.githubusercontent.com/azure/azvmimagebuilder/master/solutions/12_Creating_AIB_Security_Roles/aibRoleImageCreation.json" 
$aibRoleImageCreationPath = "aibRoleImageCreation.json"

# Download the configuration 
Invoke-WebRequest -Uri $aibRoleImageCreationUrl -OutFile $aibRoleImageCreationPath -UseBasicParsing 
((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $aibRoleImageCreationPath 
((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<rgName>', $imageResourceGroup) | Set-Content -Path $aibRoleImageCreationPath 
((Get-Content -path $aibRoleImageCreationPath -Raw) -replace 'Azure Image Builder Service Image Creation Role', $imageRoleDefName) | Set-Content -Path $aibRoleImageCreationPath

# Create a role definition 
New-AzRoleDefinition -InputFile  ./aibRoleImageCreation.json

# Grant the role definition to the VM Image Builder service principal 
New-AzRoleAssignment -ObjectId $identityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$imageResourceGroup"

# Gallery name 
$galleryName= "devboxGallery"

# Additional replication region 
$replRegion2="germanywestcentral"

# Create the gallery 
New-AzGallery -GalleryName $galleryName -ResourceGroupName $imageResourceGroup -Location $location

$SecurityType = @{Name='SecurityType';Value='TrustedLaunch'} 
$features = @($SecurityType)
function Start-CustomImageBuild {
    param(
        [Parameter(Mandatory=$true)]
        [string]$originalTemplateFilename,
        
        [Parameter(Mandatory=$true)]
        [string]$imageDefName,
        
        [Parameter(Mandatory=$true)]
        [string]$imageTemplateName
    )
    
    try {
        Write-Host "Starting custom image build process for: $imageDefName" -ForegroundColor Green
        
        # Check if image definition already exists
        $existingImageDef = Get-AzGalleryImageDefinition -GalleryName $galleryName -ResourceGroupName $imageResourceGroup -Name $imageDefName -ErrorAction SilentlyContinue
        if (!$existingImageDef) {
            Write-Host "Creating image definition: $imageDefName" -ForegroundColor Cyan
            New-AzGalleryImageDefinition -GalleryName $galleryName -ResourceGroupName $imageResourceGroup -Location $location -Name $imageDefName -OsState generalized -OsType Windows -Publisher 'CustomOrg' -Offer "devbox-custom-$($imageDefName)" -Sku '2024-1' -Feature $features -HyperVGeneration "V2"
        } else {
            Write-Host "Image definition already exists, skipping creation" -ForegroundColor Yellow
        }

        # Verify template file exists
        if (!(Test-Path $originalTemplateFilename)) {
            throw "Template file not found: $originalTemplateFilename"
        }

        # Create working copy of template with custom naming
        $workingTemplateName = "processed-template-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        Copy-Item -Path $originalTemplateFilename -Destination $workingTemplateName -Force
        
        # Process template with variable substitution
        $processedTemplatePath = Join-Path -Path (Get-Location) -ChildPath $workingTemplateName
        
        $templateContent = Get-Content -path $processedTemplatePath -Raw
        $templateContent = $templateContent -replace '<subscriptionID>', $subscriptionID
        $templateContent = $templateContent -replace '<rgName>', $imageResourceGroup
        $templateContent = $templateContent -replace '<runOutputName>', $runOutputName
        $templateContent = $templateContent -replace '<imageDefName>', $imageDefName
        $templateContent = $templateContent -replace '<sharedImageGalName>', $galleryName
        $templateContent = $templateContent -replace '<region1>', $location
        $templateContent = $templateContent -replace '<region2>', $replRegion2
        $templateContent = $templateContent -replace '<imgBuilderId>', $identityNameResourceId
        Set-Content -Path $processedTemplatePath -Value $templateContent

        # Clean up existing template if present
        $currentTemplate = Get-AzImageBuilderTemplate -ImageTemplateName $imageTemplateName -ResourceGroupName $imageResourceGroup -ErrorAction SilentlyContinue
        if ($currentTemplate) {
            Write-Host "Removing existing template: $imageTemplateName" -ForegroundColor Yellow
            Remove-AzImageBuilderTemplate -ImageTemplateName $imageTemplateName -ResourceGroupName $imageResourceGroup
        }

        # Deploy the template
        Write-Host "Deploying image builder template..." -ForegroundColor Cyan
        New-AzResourceGroupDeployment -ResourceGroupName $imageResourceGroup -TemplateFile $processedTemplatePath -Api-Version "2020-02-14" -imageTemplateName $imageTemplateName -svclocation $location

        # Start the build process
        Write-Host "Initiating image build process..." -ForegroundColor Cyan
        Invoke-AzResourceAction -ResourceName $imageTemplateName -ResourceGroupName $imageResourceGroup -ResourceType Microsoft.VirtualMachineImages/imageTemplates -ApiVersion "2020-02-14" -Action Run -Force

        # Monitor build status until completion
        Write-Host "Monitoring build progress (checking every 10 seconds)..." -ForegroundColor Cyan
        do {
            Start-Sleep -Seconds 10
            $buildStatus = Get-AzImageBuilderTemplate -ImageTemplateName $imageTemplateName -ResourceGroupName $imageResourceGroup
            $currentState = $buildStatus.LastRunStatusRunState
            $currentMessage = $buildStatus.LastRunStatusMessage
            
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Current Status: $currentState" -ForegroundColor Yellow
            if ($currentMessage) {
                Write-Host "Message: $currentMessage" -ForegroundColor Gray
            }
            
        } while ($currentState -eq "Running" -or $currentState -eq "Building" -or [string]::IsNullOrEmpty($currentState))
        
        # Final status report
        Write-Host "`nBuild completed with status: $currentState" -ForegroundColor Green
        if ($currentState -eq "Succeeded") {
            Write-Host "Image build successful!" -ForegroundColor Green
        } else {
            Write-Host "Image build failed or encountered issues. Check Azure portal for details." -ForegroundColor Red
        }
        
        # Cleanup temporary template file
        Remove-Item -Path $processedTemplatePath -ErrorAction SilentlyContinue
        
        return $buildStatus
    }
    catch {
        Write-Host "Error in Start-CustomImageBuild: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# Image definition name 
$imageDefName ="wsl2TemplateV13"
# Image template name  
$imageTemplateName="wsl2WinTemplateV13"

$templateFilename="wsl2TemplateV13.json"

# Call the new function instead of inline code
Start-CustomImageBuild -originalTemplateFilename $templateFilename -imageDefName $imageDefName -imageTemplateName $imageTemplateName