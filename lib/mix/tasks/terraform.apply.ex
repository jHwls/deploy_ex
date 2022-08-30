defmodule Mix.Tasks.Terraform.Apply do
  use Mix.Task

  @shortdoc "Deploys to terraform resources using ansible"
  @moduledoc """
  Deploys with terraform to AWS
  """

  def run(_args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployExHelpers.run_command_with_input("terraform apply", "./deploys/terraform")
    end
  end
end
