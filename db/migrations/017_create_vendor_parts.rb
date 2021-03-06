Sequel.migration do
  change do
    create_table(:vendor_parts) do
      primary_key :id
      String :part_number, :null => false, :unique => false
      Integer :vendor_id, :null => false
      Integer :qty_per_unit, :null => false
      String :name, :null => false
      Double :unit_cost
      String :link
      Text :notes
    end
  end
end
