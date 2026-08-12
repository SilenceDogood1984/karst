# frozen_string_literal: true

namespace :karst do
  desc "List zero-argument scopes declared directly in application model source. Never executes them."
  task populations: :environment do
    require "karst/access/population_discovery"
    require "karst/access/population_approvals"

    result = Karst::Access::PopulationDiscovery.new.call
    approvals = Karst::Access::PopulationApprovals.load
    groups = result.model_groups.reject { |group| group.candidate_names.empty? }

    puts "Warning: #{result.load_warning}\n\n" if result.load_warning
    puts "Warning: #{approvals.error}\n\n" if approvals.error
    puts "No candidate scopes were discovered." if groups.empty?

    groups.each do |group|
      label = group.principal_source ? " (principal source: #{group.principal_source})" : ""
      puts "#{group.model_name}#{label} -- #{group.candidate_names.size} scope(s)"
      group.candidate_names.each do |name|
        puts "  #{name}#{' [approved]' if approvals.approved?(group.model_name, name)}"
      end
    end

    puts "", <<~NOTES
      These are discovered scopes only -- Karst has not verified any of them return a usable relation,
      and none of this grants access or is wired into sampling on its own.
      Only scopes declared directly on application models are included; concern-defined scopes may not appear.
      Approve the ones Karst may try at /karst/populations. Approvals are stored locally in
      #{Karst::Access::PopulationApprovals.display_path}; delete that file to reset them.
      config.principal_populations remains supported and always takes precedence.
    NOTES
  end
end
