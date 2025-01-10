Steps for Upgrading a Server (SKU and Data Disk)
This section provides step-by-step instructions for performing server upgrades, including VM SKU changes and data disk updates, using parameter files and running pipelines for deployment.

1. Steps for Upgrading VM SKU Using Parameter Files
Step 1: Update the Parameter File

Navigate to the parameter file associated with the environment (e.g., dev, QC, prod).
Modify the vmSize parameter to reflect the desired SKU:
json
Copy code
"parameters": {
    "vmSize": {
        "value": "Standard_D4s_v3"
    }
}
Save the changes to the parameter file.
Step 2: Raise a Pull Request (PR)

Push the updated parameter file to the repository.
Raise a PR for review and approval.
Step 3: Run the Deployment Pipeline

Once the PR is approved and merged, trigger the deployment pipeline for the updated environment.
Monitor the pipeline for successful execution.
Step 4: Verify the Update

After the pipeline deployment completes, verify the VM SKU update in Azure:
bash
Copy code
az vm show --resource-group <resource-group-name> --name <vm-name> --query "hardwareProfile.vmSize"
2. Steps for Upgrading Data Disk Using Parameter Files and PowerShell Scripts
Step 1: Update the Parameter File

Open the parameter file for the environment.
Add or update the dataDiskSize value:
json
Copy code
"parameters": {
    "dataDiskSize": {
        "value": 1024  # Size in GB
    }
}
Save the file and push it to the repository.
Step 2: Raise a Pull Request (PR)

Push the updated parameter file to the repository and create a PR.
Get approval and merge the changes.
Step 3: Run the Deployment Pipeline

Trigger the deployment pipeline to apply the data disk update using the modified parameter file.
Monitor the pipeline logs for success.
Step 4: Handle Complex Updates Using PowerShell (If Needed)

If specific updates (e.g., SKU changes) are not supported through ARM templates or require custom steps, use PowerShell:
powershell
Copy code
$ResourceGroup = "<resource-group-name>"
$VMName = "<vm-name>"
$DiskName = "<disk-name>"
$NewSizeGB = 1024

$VM = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName
$Disk = $VM.StorageProfile.DataDisks | Where-Object { $_.Name -eq $DiskName }
$Disk.DiskSizeGB = $NewSizeGB
Update-AzVM -ResourceGroupName $ResourceGroup -VM $VM
3. Deployment Workflow for Upgrades
Modify Parameter File: Update the respective parameter file for SKU or data disk changes.
Raise and Approve PR: Ensure changes are reviewed and approved.
Run Pipeline: Deploy updates via the approved pipeline.
Verify: Confirm updates in Azure Portal or using CLI commands.
