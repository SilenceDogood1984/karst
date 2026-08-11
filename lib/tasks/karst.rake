# frozen_string_literal: true

namespace :karst do
  desc "List discovered candidate populations: application ActiveRecord models and their candidate " \
       "scope-shaped class methods. Never executes any of them -- see Karst::Access::PopulationDiscovery."
  task populations: :environment do
    require "karst/access/population_discovery"

    result = Karst::Access::PopulationDiscovery.new.call

    if result.load_warning
      puts "Warning: #{result.load_warning}"
      puts
    end

    groups = result.model_groups.reject { |group| group.candidate_names.empty? }
    if groups.empty?
      puts "No candidate populations were discovered."
    else
      groups.each do |group|
        label = group.principal_source ? " (principal source: #{group.principal_source})" : ""
        puts "#{group.model_name}#{label} -- #{group.candidate_names.size} candidate(s)"
        group.candidate_names.each { |name| puts "  #{name}" }
      end
    end

    puts
    puts "These are discovered candidates only -- Karst has not verified any of them return a usable " \
         "relation, and none of this grants access or is wired into sampling on its own."
    puts "Curate a selection and generate a config snippet at /karst/populations, " \
         "or configure config.principal_populations by hand."
  end
end
