require_relative 'dynamic_grammar'

module Sequitur # Module for classes implementing the Sequitur algorithm

class SequiturGrammar < DynamicGrammar
  # A hash with pairs of the form: digram key => digram
  attr_reader(:digrams)

  # The input
  attr_reader(:parsed)

  # Constructor. Build the grammar from an enumerator of tokens
  def initialize(anEnum)
    super()
    # Make start production compliant with utility rule
    2.times { root.add_backref(root) }

    @digrams = {}
    @parsed = []
    anEnum.each { |a_token| add_token(a_token) }
  end

  public

  # Add the given token to the grammar.
  def add_token(aToken)
    parsed << aToken
    super
  end

  # Check the invariant:
  # Every digram appearing in a rhs must occur at most once in the grammar.
  def check_unicity()
    all_digrams = {}
    productions.each do |a_prod|
      prod_digrams = a_prod.digrams
      prod_digrams.each do |a_digram|
        if all_digrams.include? a_digram.key
          msg = "Digram #{a_digram.symbols} occurs twice!"
          colliding = all_digrams[a_digram.key]
          msg << "\nOnce in production #{colliding.production_id}"
          msg << "\nSecond in production #{a_prod.object_id}"
          msg << "\n#{to_string}"
          fail StandardError, msg
        else
          all_digrams[a_digram.key] = a_digram
        end
      end
    end
  end


  private

  # Assumption: last digram of production isn't yet registered.
  def add_production(aProduction)
    super # Call original method from superclass...
    
    # ... then add this behaviour 
    last_digram = aProduction.last_digram
    digrams[last_digram.key] = last_digram
  end

  # Remove a production from the grammar
  def delete_production(anIndex)
    prod = productions[anIndex]

    # Retrieve in the Hash all registered digrams from the removed production
    digrams_subset = digrams.select do |_, digr|
      digr.production_id == prod.object_id
    end

    # Remove them...
    digrams_subset.each_key { |a_key| digrams.delete(a_key) }
    super
  end

  def append_symbol_to(aProduction, aSymbol)
    prod_digrams = aProduction.calc_append_symbol(aSymbol)
    check_digrams # TODO: remove this
    check_backrefs # TODO: remove this
    super
    unless prod_digrams.empty?
      last_digram = prod_digrams.last
      matching_digram = digrams[last_digram.key]
      if matching_digram.nil?
        # ... No registered occurrence of the digram, then register it
        digrams[last_digram.key] = last_digram
      else
        # Digram is already registered...
        # the digram unicity rule is broken: fix this
        preserve_unicity(aProduction)
        enforce_rule_utility
      end
    end
  end

  # The given production breaks the digram unicity rule.
  # Fix this either by a creating a new production having the duplicate
  # digram as its rhs or by referencing such a production.
  # then by replacing all occurrences of the digram by reference to
  # the fixing production.
  # Pre-condition: the given production has a repeated digram
  # or its last digram is used elsewhere
  def preserve_unicity(aProduction)
    last_digram = aProduction.last_digram
    matching_digram = digrams[last_digram.key]
    if last_digram.production_id == matching_digram.production_id
      # Rule: no other production distinct from aProduction should have
      # the matching digram
      productions.each do |prod|
        its_digrams = prod.digrams
        its_keys = its_digrams.map(&:key)
        if prod.object_id == last_digram.production_id
          # TODO: check that digram really occurs twice in the production.
          # occurrences = its_keys.select { |a_key| a_key == last_digram.key }
          # if occurrences.size != 2
          #   msg = "Digram #{last_digram.symbols} should occur twice"
          #   msg << "\nin production #{aProduction.object_id}"
          #   msg << "\nBut occurs #{occurrences.size}"
          #   msg << "\n#{self.to_string}"
          #   fail StandardError, msg
          # end

        else
          if its_keys.include? last_digram.key
            msg = "Digram #{last_digram.symbols} occurs three times!"
            msg << "\nTwice in production #{aProduction.object_id}"
            msg << "\nThird in production #{prod.object_id}"
            msg << "\n#{to_string}"
            fail StandardError, msg
          end
        end
      end

      # Digram appears twice in given production...
      # Then create a new production with the digram as its rhs
      new_prod = Production.new
      new_prod.append_symbol(last_digram.symbols[0])
      new_prod.append_symbol(last_digram.symbols[1])

      # ... replace duplicate digram by reference to new production
      aProduction.replace_digram(new_prod)
      add_production(new_prod)
      update_digrams_from(aProduction)
      check_digrams # TODO: remove
      check_unicity
    else
      # Duplicate digram used in distinct production
      # Two cases: other production is a single digram one or a multi-digram
      other_prod = ObjectSpace._id2ref(matching_digram.production_id)
      if other_prod.single_digram?
        # ... replace duplicate digram by reference to other production
        aProduction.replace_digram(other_prod)
        update_digrams_from(aProduction)

        # Special case a: replacement causes another digram duplication 
        #   in the given production
        # Special case b: replacement causes another digram duplication 
        #   with other production
        if aProduction.repeated_digram? || digrams[aProduction.last_digram.key]
          preserve_unicity(aProduction)
        end

        check_references # TODO: remove this
      else
        # aProduction, other_prod use both the same digram
        # Then create a new production with the digram as its rhs
        new_prod = Production.new
        new_prod.append_symbol(last_digram.symbols[0])
        new_prod.append_symbol(last_digram.symbols[1])

        # ... replace duplicate digram by reference to new production
        aProduction.replace_digram(new_prod)
        other_prod.replace_digram(new_prod)
        add_production(new_prod)
        update_digrams_from(aProduction)

        # TODO: Check when aProduction and other_prod have same preceding symbol
        update_digrams_from(other_prod)
        check_backrefs # TODO: remove this
      end
      check_unicity
    end

    check_unicity
    check_registered
  end

  # Rule utility: except for the root production, every production must occur
  # multiple times in all the rhs.
  # Initialize occurrence hash with pairs: production id => []
  # For each production:
  #   - Detect occurrence of any production in the rhs
  #   - Identify the occurring production
  #   - In the occurrence hash push the production id of the lhs
  # Select each production that occurs once (singleton rule):
  # Replace the occurrence in the rhs by the rhs of the singleton rule
  # Delete the singleton rule
  # Update digrams
  def enforce_rule_utility()
    return if productions.size < 2
    check_references

    loop do
      all_refcount_ok = true
      (1...productions.size).to_a.reverse.each do |index|
        next unless productions[index].refcount == 1

        all_refcount_ok = false
        other_id = productions[index].backrefs.keys.first
        dependent = ObjectSpace._id2ref(other_id)
        dependent.replace_production(productions[index])
        delete_production(index)
        update_digrams_from(dependent)
        check_references
        check_backrefs
      end

      break if all_refcount_ok
    end
  end


  # Update the digrams Hash with the digrams from the given production.
  def update_digrams_from(aProduction)
    current_digrams = aProduction.digrams

    # Add new digrams
    current_digrams.each do |digr|
      digrams[digr.key] = digr unless digrams.include? digr.key
    end

    # Retrieve all registered digrams from the production
    digrams_subset = digrams.select do |_, digr|
      digr.production_id == aProduction.object_id
    end

    # Remove obsolete digrams
    current_keys = current_digrams.map(&:key)
    digrams_subset.keys.each do |a_key|
      digrams.delete(a_key) unless current_keys.include? a_key
    end
  end

  # Check the invariant:
  # Every production reference in a rhs must point
  # to a production of the grammar.
  def check_references()
    productions.each do |a_prod|
      rhs_prods = a_prod.references
      rhs_prods.each do |referenced_prod|
        next if productions.include? referenced_prod

        msg = "Production #{a_prod.object_id} references the "
        msg << "unknown production #{referenced_prod.object_id}"
        msg << "\nOrphan production: #{referenced_prod.to_string}"
        msg << "\n#{to_string}"
        fail StandardError, msg
      end
    end
  end

  # Check the invariant:
  # Every registered digram must reference a production from the grammar
  def check_registered()
    digrams.each do |_key, digr|
      found = productions.find do |a_prod|
        digr.production_id == a_prod.object_id
      end
      next if found

      msg = "Digram #{digr.symbols} references the unknown "
      msg << "production (#{digr.production_id})."
      msg << "\n#{to_string}"
      fail StandardError, msg
    end
  end

  # Compare the contents of digrams Hash with
  # All digrams from all productions
  def check_digrams()
    # Control that every registered digram refers
    # to a production that really has that digram
    digrams.each do |key, digr|
      its_prod = ObjectSpace._id2ref(digr.production_id)
      prod_digrams = its_prod.digrams
      prod_keys = prod_digrams.map(&:key)
      next if prod_keys.include? key

      msg = "Production #{digr.production_id} doesn't have "
      msg << "the digram #{digr.symbols}"
      msg << "\n#{prod_digrams.map(&:symbols)}"
      msg << "\n#{to_string}"
      fail StandardError, msg
    end

    all_digrams = {}
    productions.each do |a_prod|
      its_digrams = a_prod.digrams
      its_digrams.each do |digr|
        check_unicity if all_digrams[digr.key]
        all_digrams[digr.key] = digr
      end
    end

    all_digrams.each do |key, digr|
      registered = digrams[key]
      if registered
        if registered.production_id != digr.production_id
          msg = "Production #{digr.production_id} has "
          msg << "the digram #{digr.symbols} that collides"
          msg << "\n with same digram from #{registered.production_id}"
          msg << "\n#{to_string}"
          fail StandardError, msg
        end
      else
        its_prod = ObjectSpace._id2ref(digr.production_id)
        msg = "Production #{its_prod.object_id} (#{its_prod.rhs}) "
        msg << "has the digram #{digr.symbols} that isn't registered."
        msg << "\n#{to_string}"
        fail StandardError, msg
      end
    end
  end


end # class

end # module

# End of file