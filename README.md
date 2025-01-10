Steps to Upgrade a Server (SKU and Data Disk)
When performing upgrades to servers such as changing the VM SKU or updating the data disk size, we follow a structured process to ensure consistency and minimize risks. Here's the high-level workflow:

1. Updating VM SKU
Modify Parameter Files:

Instead of directly editing the ARM template, we use parameter files. These files define the configurations for the VMs (e.g., size, region, and other specifications).
For an SKU update, we change the vmSize value in the relevant parameter file corresponding to the environment (e.g., dev, QC, prod).
Push and Review Changes:

The updated parameter file is pushed to the repository, and a Pull Request (PR) is raised. This allows team members to review and approve the changes.
Deploy via Pipeline:

Once the PR is approved and merged, we run the deployment pipeline. The pipeline uses the updated parameter file to apply the changes.
Verify the Upgrade:

After the deployment completes, the VM SKU is verified through the Azure portal or other tools to confirm the update.
2. Updating Data Disk Size
Modify Parameter Files:

For data disk updates, the dataDiskSize parameter is updated in the parameter file. This ensures that changes are applied in a controlled manner and not directly in the ARM template.
Raise PR and Approval:

Similar to SKU updates, the changes are reviewed through a PR process and approved by the appropriate team members.
Deploy via Pipeline:

The pipeline is triggered to deploy the updated configurations to the server.
Advanced Updates with PowerShell (Optional):

For complex updates (e.g., when certain changes are not fully supported by ARM templates), PowerShell scripts can be used to handle such scenarios. This is done only when necessary.
Key Workflow and Best Practices
Separation of Configurations:

All updates are made in parameter files specific to each environment. This approach ensures that configurations remain consistent and easy to manage.
Approval Process:

All changes are reviewed through a formal PR process to avoid errors and maintain quality control.
Automated Deployment:

Pipelines are used to automate the deployment of updates, ensuring reliability and reducing manual intervention.
Verification:

Each change is verified in the Azure portal or using CLI tools to ensure the update has been applied successfully.
