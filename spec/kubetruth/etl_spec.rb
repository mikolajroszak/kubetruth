require 'rspec'
require 'kubetruth/etl'

module Kubetruth
  describe ETL do

    let(:init_args) {{
      kube_context: {}
    }}
    let(:etl) { described_class.new(init_args) }

    def kubeapi
      kapi = double(Kubetruth::KubeApi)
      allow(Kubetruth::KubeApi).to receive(:new).and_return(kapi)
      allow(kapi).to receive(:get_resource).and_return(Kubeclient::Resource.new)
      allow(kapi).to receive(:apply_resource)
      allow(kapi).to receive(:under_management?).and_return(true)
      allow(kapi).to receive(:ensure_namespace)
      allow(kapi).to receive(:namespace).and_return("default")
      allow(kapi).to receive(:get_project_mappings).and_return([])
      kapi
    end

    before(:each) do
      @kubeapi = kubeapi
    end

    describe "#kubeapi" do

      it "passes namespace to ctor" do
        etl = described_class.new(kube_context: {namespace: "foo"})
        expect(Kubetruth::KubeApi).to receive(:new).with(namespace: "foo")
        etl.kubeapi
      end

      it "is memoized" do
        etl = described_class.new(init_args)
        allow(Kubetruth::KubeApi).to receive(:new)
        expect(etl.kubeapi).to equal(etl.kubeapi)
      end

    end

    describe "#interruptible_sleep" do

      it "runs for interval without interruption" do
        etl = described_class.new(init_args)
        t = Time.now.to_f
        etl.interruptible_sleep(0.2)
        expect(Time.now.to_f - t).to be >= 0.2
      end

      it "can be interrupted" do
        etl = described_class.new(init_args)
        Thread.new do
          sleep 0.1
          etl.interrupt_sleep
        end
        t = Time.now.to_f
        etl.interruptible_sleep(0.5)
        expect(Time.now.to_f - t).to be < 0.2
      end

    end

    describe "#with_polling" do

      class ForceExit < Exception; end

      it "runs with an interval" do
        etl = described_class.new(init_args)

        watcher = double()
        expect(@kubeapi).to receive(:watch_project_mappings).and_return(watcher).twice
        expect(watcher).to receive(:each).twice
        expect(watcher).to receive(:finish).twice
        expect(etl).to receive(:apply).twice

        count = 0
        expect(etl).to receive(:interruptible_sleep).
          with(0.2).twice { |m, *args| count += 1; raise ForceExit if count > 1 }

        begin
          etl.with_polling(0.2) do
            etl.apply
          end
        rescue ForceExit
        end
        expect(count).to eq(2)

      end

      it "isolates run loop from block failures" do
        etl = described_class.new(init_args)

        watcher = double()
        expect(@kubeapi).to receive(:watch_project_mappings).and_return(watcher).twice
        expect(watcher).to receive(:each).twice
        expect(watcher).to receive(:finish).twice
        expect(etl).to receive(:apply).and_raise("fail").twice

        count = 0
        expect(etl).to receive(:interruptible_sleep).
          with(0.2).twice { |m, *args| count += 1; raise ForceExit if count > 1 }

        begin
          etl.with_polling(0.2) do
            etl.apply
          end
        rescue ForceExit
        end
        expect(count).to eq(2)

      end

      it "interrupts sleep on watch event" do
        etl = described_class.new(init_args)

        watcher = double()
        notice = double("notice", type: "UPDATED", object: double("kube_resource"))
        expect(@kubeapi).to receive(:watch_project_mappings).and_return(watcher)
        expect(watcher).to receive(:each).and_yield(notice)
        expect(watcher).to receive(:finish)
        expect(etl).to receive(:apply)
        expect(etl).to receive(:interrupt_sleep)

        expect(etl).to receive(:interruptible_sleep).
          with(0.2) { |m, *args| sleep(0.2); raise ForceExit }

        begin
          etl.with_polling(0.2) do
            etl.apply
          end
        rescue ForceExit
        end

      end

    end

    describe "#load_config" do

      it "loads config" do
        expect(@kubeapi).to receive(:get_project_mappings).and_return([])
        etl = described_class.new(init_args)
        config = etl.load_config
        expect(config).to be_an_instance_of(Kubetruth::Config)
      end

    end

    describe "#kube_apply" do

      it "calls kube to create new resource" do
        resource_yml = <<~EOF
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: "group1"
          data:
            "param1": "value1"
        EOF
        expect(@kubeapi).to receive(:ensure_namespace).with(@kubeapi.namespace)
        expect(@kubeapi).to receive(:get_resource).with("configmaps", "group1", @kubeapi.namespace).and_raise(Kubeclient::ResourceNotFoundError.new(1, "", 2))
        expect(@kubeapi).to_not receive(:under_management?)
        expect(@kubeapi).to receive(:apply_resource).with(YAML.load(resource_yml))
        etl.kube_apply(resource_yml)
        expect(Logging.contents).to match(/Creating kubernetes resource/)
      end

      it "calls to kube to update existing resource" do
        resource_yml = <<~EOF
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: "group1"
          data:
            "param1": "value1"
        EOF
        resource_hash = YAML.load(resource_yml)
        resource = Kubeclient::Resource.new(resource_hash.merge(data: {param1: "oldvalue"}))
        expect(@kubeapi).to receive(:get_resource).with("configmaps", "group1", @kubeapi.namespace).and_return(resource)
        expect(@kubeapi).to receive(:under_management?).and_return(true)
        expect(@kubeapi).to receive(:apply_resource).with(resource_hash)
        etl.kube_apply(resource_yml)
        expect(Logging.contents).to match(/Updating kubernetes resource/)
      end

      it "skips call to kube for existing resource not under management" do
        resource_yml = <<~EOF
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: "group1"
          data:
            "param1": "value1"
        EOF
        resource = Kubeclient::Resource.new(YAML.load(resource_yml))
        expect(@kubeapi).to receive(:get_resource).with("configmaps", "group1", @kubeapi.namespace).and_return(resource)
        expect(@kubeapi).to receive(:under_management?).and_return(false)
        expect(@kubeapi).to_not receive(:apply_resource)
        etl.kube_apply(resource_yml)
        expect(Logging.contents).to match(/Skipping.*kubetruth management/)
      end

      it "doesn't update resource if data same" do
        resource_yml = <<~EOF
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: "group1"
          data:
            "param1": "value1"
        EOF
        resource_hash = YAML.load(resource_yml)
        resource = Kubeclient::Resource.new(resource_hash)
        expect(@kubeapi).to receive(:get_resource).with("configmaps", "group1", @kubeapi.namespace).and_return(resource)
        expect(@kubeapi).to receive(:under_management?).and_return(true)
        expect(@kubeapi).to_not receive(:apply_resource).with(resource_hash)
        etl.kube_apply(resource_yml)
        expect(Logging.contents).to match(/Skipping update for identical kubernetes resource/)
      end

      it "uses namespace for kube when supplied" do
        resource_yml = <<~EOF
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: "group1"
            namespace: "ns1"
          data:
            "param1": "value1"
        EOF
        expect(@kubeapi).to receive(:ensure_namespace).with("ns1")
        expect(@kubeapi).to receive(:get_resource).with("configmaps", "group1", "ns1").and_raise(Kubeclient::ResourceNotFoundError.new(1, "", 2))
        expect(@kubeapi).to_not receive(:under_management?)
        expect(@kubeapi).to receive(:apply_resource).with(YAML.load(resource_yml))
        etl.kube_apply(resource_yml)
        expect(Logging.contents).to match(/Creating kubernetes resource/)
      end

    end

    describe "#apply" do

      before(:each) do
        default_root_spec = YAML.load_file(File.expand_path("../../helm/kubetruth/values.yaml", __dir__)).deep_symbolize_keys
        @root_spec_crd = default_root_spec[:projectMappings][:root]
        allow(etl).to receive(:load_config).and_return(Kubetruth::Config.new([@root_spec_crd]))
        allow(Project).to receive(:create).and_wrap_original do |m, *args|
          project = m.call(*args)
          allow(project).to receive(:parameters).and_return([
                                                              Parameter.new(key: "param1", value: "value1", secret: false),
                                                              Parameter.new(key: "param2", value: "value2", secret: true)
                                                            ])
          project
        end
      end

      it "sets config and secrets" do
        expect(Project).to receive(:names).and_return(["proj1"])

        allow(etl).to receive(:kube_apply) do |yml|
          if yml.include?("kind: ConfigMap")
            expect(yml).to match(/"param1": "value1"/)
            expect(yml).to_not match(/"param2": "value2"/)
          elsif yml.include?("kind: Secret")
            expect(yml).to_not match(/"param1": "value1"/)
            expect(yml).to match(/"param2": "#{Base64.strict_encode64('value2')}"/)
          else
            raise "Unexpected kubernetes resource kind"
          end
        end

        etl.apply()
      end

      it "skips secrets" do
        expect(Project).to receive(:names).and_return(["proj1"])
        etl.load_config.root_spec.skip_secrets = true

        allow(etl).to receive(:kube_apply) do |yml|
          if yml.include?("kind: ConfigMap")
            expect(yml).to match(/"param1": "value1"/)
            expect(yml).to_not match(/"param2": "value2"/)
          elsif yml.include?("kind: Secret")
            raise "Secret should not be present"
          else
            raise "Unexpected kubernetes resource kind"
          end
        end

        etl.apply()
      end

      it "allows dryrun" do
        etl.instance_variable_set(:@dry_run, true)
        expect(Project).to receive(:names).and_return(["proj1"])

        expect(@kubeapi).to_not receive(:ensure_namespace)
        expect(@kubeapi).to_not receive(:apply_resource)

        etl.apply()
        expect(Logging.contents).to match("Performing dry-run")
      end

      it "skips projects when selector fails" do
        etl.load_config.root_spec.project_selector = /oo/
        expect(Project).to receive(:names).and_return(["proj1", "foo", "bar"])

        allow(etl).to receive(:kube_apply) do |yml|
          expect(yml).to match(/name: "foo"/)
        end

        etl.apply()
      end

      it "skips projects if flag is set" do
        allow(etl).to receive(:load_config).
          and_return(Kubetruth::Config.new([@root_spec_crd, {scope: "override", project_selector: "foo", skip: true}]))
        expect(Project).to receive(:names).and_return(["proj1", "foo", "bar"])

        allow(etl).to receive(:kube_apply) do |yml|
          expect(yml).to match(/name: "((proj1)|(bar))"/)
        end

        etl.apply()
      end

      it "allows included projects not selected by selector" do
        etl.load_config.root_spec.project_selector = /proj1/
        etl.load_config.root_spec.included_projects = ["proj2"]
        expect(Project).to receive(:names).and_return(["proj1", "proj2", "proj3"])

        allow(etl).to receive(:kube_apply)
        expect(etl.load_config.root_spec.configmap_template).to receive(:render) do |*args, **kwargs|
          expect(kwargs[:project]).to eq("proj1")
          expect(kwargs[:project_heirarchy]).to eq({"proj1"=>{"proj2"=>{}}})
          expect(kwargs[:parameter_origins]).to eq({"param1"=>"proj1 (proj2)"})
        end

        etl.apply()
      end

      it "allows projects not selected by root selector" do
        allow(etl).to receive(:load_config).
          and_return(Kubetruth::Config.new([
                                             @root_spec_crd,
                                             {scope: "override", project_selector: "proj2"}
                                           ]
          ))
        etl.load_config.root_spec.project_selector = /proj1/
        expect(Project).to receive(:names).and_return(["proj2"])

        allow(etl).to receive(:kube_apply) do |yml|
          expect(yml).to match(/name: "proj2"/)
        end

        etl.apply()
      end


      it "renders templates with context" do
        expect(Project).to receive(:names).and_return(["proj1"])

        allow(etl).to receive(:kube_apply)
        expect(etl.load_config.root_spec.configmap_template).to receive(:render) do |*args, **kwargs|
          expect(kwargs[:project]).to eq("proj1")
          expect(kwargs[:debug]).to eq(etl.logger.debug?)
          expect(kwargs[:parameters]).to eq({"param1"=>"value1"})
          expect(kwargs[:project_heirarchy]).to eq(Project.all["proj1"].heirarchy)
          expect(kwargs[:parameter_origins]).to eq({"param1"=>"proj1"})
        end

        expect(etl.load_config.root_spec.secret_template).to receive(:render) do |*args, **kwargs|
          expect(kwargs[:project]).to eq("proj1")
          expect(kwargs[:debug]).to eq(etl.logger.debug?)
          expect(kwargs[:parameters]).to eq({"param2"=>"value2"})
          expect(kwargs[:project_heirarchy]).to eq(Project.all["proj1"].heirarchy)
          expect(kwargs[:parameter_origins]).to eq({"param2"=>"proj1"})
        end

        etl.apply()
      end
    end

  end
end
