defmodule Mix.Tasks.Terraform.Build do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()
  @default_aws_region DeployEx.Config.aws_region()

  @shortdoc "Builds/Updates terraform files or adds it to your project"
  @moduledoc """
  Builds or updates terraform files within the project.

  ## Options
  - `directory` - Directory for the terraform files (default: `#{@terraform_default_path}`)
  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `env` - Environment for terraform (default: `Mix.env()`)
  - `quiet` - Supress output
  - `force` - Force create files without asking
  - `verbose` - Log extra details about the process

  """

  def run(args) do
    opts = args
      |> parse_args
      |> Keyword.put_new(:directory, @terraform_default_path)
      |> Keyword.put_new(:aws_region, @default_aws_region)
      |> Keyword.put_new(:aws_bucket, DeployEx.Config.aws_release_bucket())
      |> Keyword.put_new(:env, Mix.env())

    opts = opts
      |> Keyword.put_new(:variables_file, Path.join(opts[:directory], "variables.tf"))
      |> Keyword.put_new(:keypair_file, Path.join(opts[:directory], "key-pair-main.tf"))
      |> Keyword.put_new(:main_file, Path.join(opts[:directory], "main.tf"))

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         :ok <- ensure_terraform_directory_exists(opts[:directory]) do
      terraform_output = releases
        |> Keyword.keys
        |> Enum.map_join(",\n\n", &(&1 |> to_string |> generate_terraform_output(opts)))

      write_terraform_variables(terraform_output, opts)
      write_terraform_main(opts)
      write_terraform_keypair(opts)
      run_terraform_init(opts)
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, v: :verbose],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        verbose: :boolean,
        aws_region: :string,
        env: :string
      ]
    )

    opts
  end

  defp run_terraform_init(opts) do
    DeployExHelpers.run_command_with_input("terraform init", opts[:directory])
  end

  defp ensure_terraform_directory_exists(directory) do
    if File.exists?(directory) do
      :ok
    else
      Mix.shell().info([:green, "* copying terraform into ", :reset, directory])

      File.mkdir_p!(directory)

      "terraform"
        |> DeployExHelpers.priv_file()
        |> File.cp_r!(directory)

      :ok
    end
  end

  defp generate_terraform_output(release_name, opts) do
    String.trim_trailing("""
        #{release_name} = {
          environment = "#{opts[:env]}"
          name = "#{DeployExHelpers.upper_title_case(release_name)}"
        }
    """, "\n")
  end

  defp write_terraform_variables(terraform_output, opts) do
    if File.exists?(opts[:variables_file]) do
      opts[:variables_file]
        |> File.read!
        |> inject_terraform_contents_into_variables(terraform_output, opts)
    else
      :deploy_ex
        |> :code.priv_dir
        |> Path.join("terraform/variables.tf.eex")
        |> File.cp!("#{opts[:variables_file]}.eex")

      generate_and_delete_variables_template(terraform_output, opts)
    end
  end

  defp inject_terraform_contents_into_variables(current_file, terraform_output, opts) do
    current_file = String.split(current_file, "\n")
    project_variable_idx = Enum.find_index(
      current_file,
      &(&1 =~ "variable \"#{DeployExHelpers.underscored_app_name()}_project\"")
    ) + 4 # 4 is the number of newlines till the default key
    {start_of_file, project_variable} = Enum.split(current_file, project_variable_idx + 1)

    new_file = Enum.join(start_of_file ++ String.split(terraform_output, "\n") ++ Enum.take(project_variable, -3), "\n")

    if new_file !== current_file do
      opts = [{:message, [:green, "* injecting ", :reset, opts[:variables_file]]} | opts]

      DeployExHelpers.write_file(opts[:variables_file], new_file, opts)
    end
  end

  defp generate_and_delete_variables_template(terraform_output, opts) do
    template_file = "#{opts[:variables_file]}.eex"

    DeployExHelpers.check_file_exists!(template_file)

    variables_files = EEx.eval_file(template_file, assigns: %{
      environment: opts[:env],
      terraform_release_variables: terraform_output,
      release_bucket_name: opts[:aws_bucket],
      app_name: DeployExHelpers.underscored_app_name()
    })

    DeployExHelpers.write_file(opts[:variables_file], variables_files, opts)

    if opts[:verbose] do
      Mix.shell().info([:green, "* removing ", :reset, template_file])
    end

    File.rm!(template_file)
  end

  defp write_terraform_main(opts) do
    if File.exists?(opts[:main_file]) do
      rewrite_terraform_main_contents(opts)
    else
      generate_and_delete_main_template(opts)
    end
  end

  defp rewrite_terraform_main_contents(opts) do
    main_file_path = "terraform"
      |> Path.join(Path.basename(opts[:main_file]))
      |> DeployExHelpers.priv_file
      |> Path.expand
      |> Kernel.<>(".eex")

    DeployExHelpers.check_file_exists!(main_file_path)

    File.cp!(main_file_path, "#{opts[:main_file]}.eex")

    opts
      |> Keyword.put(:message, [
        :green, "* copying template to ", :reset, "#{opts[:main_file]}.eex\n",
        :green, "* rewriting ", :reset, opts[:main_file]
      ])
      |> generate_and_delete_main_template
  end

  defp generate_and_delete_main_template(opts) do
    template_file_path = "#{opts[:main_file]}.eex"

    DeployExHelpers.check_file_exists!(template_file_path)

    main_file = EEx.eval_file(template_file_path, assigns: %{
      aws_region: opts[:aws_region],
      aws_bucket: opts[:aws_bucket],
      app_name: DeployExHelpers.underscored_app_name()
    })

    DeployExHelpers.write_file(opts[:main_file], main_file, opts)

    if opts[:verbose] do
      Mix.shell().info([:green, "* removing ", :reset, template_file_path])
    end

    File.rm!(template_file_path)
  end

  defp write_terraform_keypair(opts) do
    if not File.exists?(opts[:keypair_file]) do
      keypair_template_path = "terraform"
        |> Path.join(Path.basename(opts[:keypair_file]))
        |> DeployExHelpers.priv_file
        |> Path.expand
        |> Kernel.<>(".eex")

      DeployExHelpers.check_file_exists!(keypair_template_path)

      kebab_case_app_name = String.replace(DeployExHelpers.underscored_app_name(), "_", "-")
      random_bytes = 6 |> :crypto.strong_rand_bytes |> Base.encode32(padding: false)

      terraform_keypair = EEx.eval_file(keypair_template_path, assigns: %{
        pem_app_name: "#{kebab_case_app_name}-#{random_bytes}"
      })

      DeployExHelpers.write_file(opts[:keypair_file], terraform_keypair, opts)
    end
  end
end
