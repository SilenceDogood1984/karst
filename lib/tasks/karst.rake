# frozen_string_literal: true

namespace :karst do
  desc "List zero-argument scopes declared directly in application model source. Never executes them."
  task populations: :environment do
    require "karst/access/population_discovery"

    result = Karst::Access::PopulationDiscovery.new.call

    if result.load_warning
      puts "Warning: #{result.load_warning}"
      puts
    end

    groups = result.model_groups.reject { |group| group.candidate_names.empty? }
    if groups.empty?
      puts "No candidate scopes were discovered."
    else
      groups.each do |group|
        label = group.principal_source ? " (principal source: #{group.principal_source})" : ""
        puts "#{group.model_name}#{label} -- #{group.candidate_names.size} scope(s)"
        group.candidate_names.each { |name| puts "  #{name}" }
      end
    end

    puts
    puts "These are discovered scopes only -- Karst has not verified any of them return a usable " \
         "relation, and none of this grants access or is wired into sampling on its own."
    puts "Only scopes declared directly on application models are included; concern-defined scopes may not appear."
    puts "Curate a selection and generate a config snippet at /karst/populations, " \
         "or configure config.principal_populations by hand."
  end
end
