module Piculet
  class Client
    include Logger::ClientHelper

    def initialize(options = {})
      @options = OpenStruct.new(options)
      @options_hash = options
      @options.ec2 = AWS::EC2.new
    end

    def apply(file)
      @options.ec2.owner_id
      AWS.memoize { walk(file) }
    end

    def patch(file, output_file)
      dsl_result = load_file(file)
      dest_data = JSON.parse File.read(output_file)

      # [vpc_name, sg.name, ingress/egress]
      dsl_result.ec2s.each do |vpc_name, ec2_result|
        ec2_result.security_groups.each do |sg|
          %w(ingress egress).each do |direction|
            sg.send(direction).each do |perm_result|
              next if perm_result.description.nil?

              error_message = <<~STR
                Unable to find permission in the destination:
                  VPC: #{vpc_name}
                  SG: #{sg.name}
                  Direction: #{direction}
                  Protocol: #{perm_result.protocol}
                  Port Range: #{perm_result.port_range}
                  Description: #{perm_result.description}
              STR

              sg_match = dest_data[vpc_name].find { |sg_id, sg_data|
                sg_data['name'] == sg.name
              }.last

              if sg_match.nil?
                log(:error, error_message, 'red')
                raise 'Permission Not Found'
              end

              perms = sg_match[direction]
              perm_match = perms.find { |perm|
                check_protocol = perm_result.protocol.to_s
                check_port_range = if perm_result.port_range.nil?
                  nil
                else
                  [perm_result.port_range.begin, perm_result.port_range.end].join('..')
                end
                proto_match = perm['protocol'] == check_protocol
                port_range_match = perm['port_range'] == check_port_range
                proto_match && port_range_match
              }

              if perm_match.nil?
                log(:error, error_message, 'red')
                raise 'Permission Not Found'
              end

              perm_match['description'] = perm_result.description
            end
          end
        end
      end

      new_filename = "#{File.basename(output_file, '.json')}-updated.json"
      File.write(new_filename, JSON.pretty_generate(dest_data))
    end

    def should_skip(sg_name, sg)
      # Name
      if @options.sg_names
        if not @options.sg_names.include?(sg_name)
          return true
        end
      end

      if @options.exclude_sgs
        if @options.exclude_sgs.any? {|regex| sg_name =~ regex}
          return true
        end
      end

      # Tag
      if @options.exclude_tags
        if sg and (@options.exclude_tags & sg.tags.keys).any?
          return true
        end
      end

      false
    end

    def export(options = {})
      exported = AWS.memoize do
        Exporter.export(@options.ec2, @options_hash.merge(options))
      end

      converter = proc do |src|
        if options[:without_convert]
          exported
        else
          DSL.convert(src, @options.ec2.owner_id)
        end
      end

      if block_given?
        yield(exported, converter)
      else
        converter.call(exported)
      end
    end

    private
    def load_file(file)
      if file.kind_of?(String)
        open(file) do |f|
          load_by_format(f.read, file)
        end
      elsif file.respond_to?(:read)
        load_by_format(file.read, file.path)
      else
        raise TypeError, "can't convert #{file} into File"
      end
    end

    def load_by_format(src, path)
      if @options.format == :json
        src = load_json(src, path)
      end

      DSL.define(src, path).result
    end

    def load_json(json, path)
      json = JSON.parse(json, :symbolize_names => true)

      if json.has_key?(:'')
        json[nil] = json.delete(:'')
      end

      DSL.convert(json, @options.ec2.owner_id)
    end

    def walk(file)
      dsl = load_file(file)

      dsl_ec2s = dsl.ec2s
      ec2 = EC2Wrapper.new(@options.ec2, @options)

      aws_ec2s = collect_to_hash(ec2.security_groups, :has_many => true) do |item|
        item.vpc? ? item.vpc_id : nil
      end

      dsl_ec2s.each do |vpc, ec2_dsl|
        if @options.ec2s
          next unless @options.ec2s.any? {|i| (i == 'classic' and vpc.nil?) or i == vpc }
        end

        ec2_aws = aws_ec2s[vpc]

        if ec2_aws
          walk_ec2(vpc, ec2_dsl, ec2_aws, ec2.security_groups)
        else
          log(:warn, "EC2 `#{vpc || :classic}` is not found", :yellow)
        end
      end

      ec2.updated?
    end

    def walk_ec2(vpc, ec2_dsl, ec2_aws, collection_api)
      sg_list_dsl = collect_to_hash(ec2_dsl.security_groups, :name)
      sg_list_aws = collect_to_hash(ec2_aws, :name)

      sg_list_dsl.each do |key, sg_dsl|
        name = key[0]
        sg_aws = sg_list_aws[key]

        next if should_skip(name, sg_aws)

        unless sg_aws
          sg_aws = collection_api.create(name, :vpc => vpc, :description => sg_dsl.description)

          if vpc and sg_dsl.egress.empty?
            log(:warn, '`egress any 0.0.0.0/0` is implicitly defined', :yellow)
          end

          sg_list_aws[key] = sg_aws
        end
      end

      sg_list_dsl.each do |key, sg_dsl|
        name = key[0]
        sg_aws = sg_list_aws.delete(key)

        next if should_skip(name, sg_aws)

        walk_security_group(sg_dsl, sg_aws)
      end

      sg_list_aws.each do |key, sg_aws|
        name = key[0]

        next if should_skip(name, sg_aws)

        sg_aws.ingress_ip_permissions.each {|i| i.delete }
        sg_aws.egress_ip_permissions.each {|i| i.delete } if vpc
      end

      sg_list_aws.each do |key, sg_aws|
        name = key[0]

        next if should_skip(name, sg_aws)

        sg_aws.delete
      end
    end

    def walk_security_group(security_group_dsl, security_group_aws)
      unless security_group_aws.eql?(security_group_dsl)
        security_group_aws.update(security_group_dsl)
      end

      walk_permissions(
        security_group_dsl.ingress,
        security_group_aws.ingress_ip_permissions)

      if security_group_aws.vpc?
        walk_permissions(
          security_group_dsl.egress,
          security_group_aws.egress_ip_permissions)
      end
    end

    def walk_permissions(permissions_dsl, permissions_aws)
      perm_list_dsl = collect_to_hash(permissions_dsl, :protocol, :port_range)
      perm_list_aws = collect_to_hash(permissions_aws, :protocol, :port_range)

      perm_list_aws.each do |key, perm_aws|
        perm_dsl = perm_list_dsl.delete(key)

        if perm_dsl
          unless perm_aws.eql?(perm_dsl)
            perm_aws.update(perm_dsl)
          end
        else
          perm_aws.delete
        end
      end

      perm_list_dsl.each do |key, perm_dsl|
        protocol, port_range = key
        permissions_aws.create(protocol, port_range, perm_dsl)
      end
    end

    def collect_to_hash(collection, *key_attrs)
      options = key_attrs.last.kind_of?(Hash) ? key_attrs.pop : {}
      hash = {}

      collection.each do |item|
        key = block_given? ? yield(item) : key_attrs.map {|k| item.send(k) }

        if options[:has_many]
          hash[key] ||= []
          hash[key] << item
        else
          hash[key] = item
        end
      end

      return hash
    end
  end # Client
end # Piculet
