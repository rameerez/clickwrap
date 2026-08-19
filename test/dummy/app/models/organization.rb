# frozen_string_literal: true

# A tenant. Clickwrap keeps actor, tenant, and subject as three separate things,
# and the dummy needs all three to prove they don't collapse into one another.
class Organization < ApplicationRecord
end
