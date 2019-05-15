# frozen_string_literal: true

require_relative 'types'
require_relative 'configuration/host'
require_relative 'configuration/api'
require_relative 'configuration/network'
require_relative 'configuration/etcd'
require_relative 'configuration/authentication'
require_relative 'configuration/cloud'
require_relative 'configuration/audit'
require_relative 'configuration/file_audit'
require_relative 'configuration/webhook_audit'
require_relative 'configuration/kube_proxy'
require_relative 'configuration/kubelet'
require_relative 'configuration/control_plane'
require_relative 'configuration/pod_security_policy'
require_relative 'configuration/telemetry'
require_relative 'configuration/admission_plugin'
require_relative 'configuration/container_runtime'

module Pharos
  class Config < Pharos::Configuration::Struct
    HOSTS_PER_DNS_REPLICA = 10

    using Pharos::CoreExt::DeepTransformKeys

    # @param raw_data [Hash]
    # @raise [Pharos::ConfigError]
    # @return [Pharos::Config]
    def self.load(raw_data)
      schema_data = Pharos::ConfigSchema.load(raw_data)

      config = new(schema_data)
      config.data = raw_data.freeze

      config.hosts.reject { |h| h.bastion.nil? }.each do |host_a|
        host_b = config.hosts.find { |host| host_a.bastion.attributes_match?(host.attributes) }
        next unless host_b

        # Creating a new Pharos::Configuration::Bastion entry because otherwise it's an anonymous class
        host_a.attributes[:bastion] = Pharos::Configuration::Bastion.new(host_a.bastion.attributes).tap { |bastion| bastion.host = host_b }

        if host_a == host_b
          raise Pharos::ConfigError, 'hosts' => { config.hosts.index(host_a) => ["host and its bastion point to the same address and port (#{host_a.address}:#{host_a.ssh_port})"] }
        end

        if host_b.bastion
          raise Pharos::ConfigError, 'hosts' => { config.hosts.index(host_a) => ["multi-hop bastion not supported (#{host_a.address}:#{host_a.ssh_port} -> #{host_a.bastion.address}:#{host_a.bastion.ssh_port} -> #{host_b.bastion.address}:#{host_b.bastion.ssh_port}"] }
        end
      end

      # de-duplicate bastions (if two hosts share an identical bastion, make it the same object to avoid multiple gateways)
      config.hosts.reject { |h| h.bastion.nil? }.permutation(2) do |host_a, host_b|
        if host_a.bastion.attributes == host_b.bastion.attributes && host_a.bastion.object_id != host_b.bastion.object_id
          host_b.attributes[:bastion] = host_a.bastion
        end
      end

      # inject api_endpoint & config reference to each host object
      config.hosts.each do |host|
        host.api_endpoint = config.api&.endpoint
        host.config = config
      end

      config
    end

    attribute :hosts, Types::Coercible::Array.of(Pharos::Configuration::Host)
    attribute :network, Pharos::Configuration::Network
    attribute :kube_proxy, Pharos::Configuration::KubeProxy
    attribute :api, Pharos::Configuration::Api
    attribute :etcd, Pharos::Configuration::Etcd
    attribute :cloud, Pharos::Configuration::Cloud
    attribute :authentication, Pharos::Configuration::Authentication
    attribute :audit, Pharos::Configuration::Audit
    attribute :kubelet, Pharos::Configuration::Kubelet
    attribute :control_plane, Pharos::Configuration::ControlPlane
    attribute :telemetry, Pharos::Configuration::Telemetry
    attribute :pod_security_policy, Pharos::Configuration::PodSecurityPolicy
    attribute :image_repository, Pharos::Types::String.default('registry.pharos.sh/kontenapharos')
    attribute :addon_paths, Pharos::Types::Array.default(proc { [] })
    attribute :addons, Pharos::Types::Hash.default(proc { {} })
    attribute :admission_plugins, Types::Coercible::Array.of(Pharos::Configuration::AdmissionPlugin)
    attribute :container_runtime, Pharos::Configuration::ContainerRuntime
    attribute :name, Pharos::Types::String

    alias all_hosts hosts

    attr_accessor :data

    # @return [Integer]
    def dns_replicas
      return network.dns_replicas if network.dns_replicas
      return 1 if hosts.length == 1

      1 + (hosts.length / HOSTS_PER_DNS_REPLICA.to_f).ceil
    end

    # @return [Array<Pharos::Configuration::Host>]
    def master_hosts
      hosts.select { |h| h.role == 'master' }.sort_by(&:master_sort_score)
    end

    # @return [Pharos::Configuration::Host]
    def master_host
      master_hosts.first
    end

    # @return [Array<Pharos::Configuration::Host>]
    def worker_hosts
      @worker_hosts ||= hosts.select { |h| h.role == 'worker' }
    end

    # @return [Array<Pharos::Configuration::Host>]
    def etcd_hosts
      return [] if etcd&.endpoints

      etcd_hosts = hosts.select { |h| h.role == 'etcd' }
      if etcd_hosts.empty?
        master_hosts.sort_by(&:etcd_sort_score)
      else
        etcd_hosts.sort_by(&:etcd_sort_score)
      end
    end

    # @return [Pharos::Configuration::Host]
    def etcd_host
      etcd_hosts.first
    end

    def local_host
      @local_host ||= hosts.select(&:local?).first || Pharos::Configuration::Host.new(address: '127.0.0.1').tap { |h| h.hostname = ENV['HOST'] || 'localhost' }
    end

    def remote_hosts
      hosts.reject(&:local?)
    end

    # @param peer [Pharos::Configuration::Host]
    # @return [String]
    def etcd_peer_address(peer)
      etcd_regions.size > 1 ? peer.address : peer.peer_address
    end

    # @return [Array<String>]
    def etcd_regions
      @etcd_regions ||= etcd_hosts.map(&:region).compact.uniq
    end

    # @return [Array<String>]
    def regions
      @regions ||= hosts.map(&:region).compact.uniq
    end

    # @param key [Symbol]
    # @param value [Pharos::Configuration::Struct]
    # @raise [Pharos::ConfigError]
    def set(key, value)
      raise Pharos::Error, "Cannot override #{key}." if data[key.to_s]

      attributes[key] = value
    end

    # @return [String]
    def to_yaml
      YAML.dump(to_h.deep_stringify_keys)
    end

    # @example dig network provider
    #   config.dig("network", "provider")
    # @param keys [String,Symbol]
    # @return [Object,nil] returns nil when any part of the chain is unreachable
    def dig(*keys)
      keys.inject(self) do |memo, item|
        if memo.is_a?(Array) && item.is_a?(Integer)
          memo.send(:[], item)
        elsif memo.respond_to?(item.to_sym)
          memo.send(item.to_sym)
        end
      end
    end
  end
end
