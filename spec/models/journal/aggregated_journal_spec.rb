#-- encoding: UTF-8
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2015 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++require 'rspec'

require 'spec_helper'

RSpec::Matchers.define :be_equivalent_to_journal do |expected|
  ignored_attributes = [:notes_id]

  match do |actual|
    expected_attributes = get_normalized_attributes expected
    actual_attributes = get_normalized_attributes actual

    expected_attributes.except(*ignored_attributes) == actual_attributes.except(*ignored_attributes)
  end

  failure_message do |actual|
    expected_attributes = get_normalized_attributes expected
    actual_attributes = actual.attributes.symbolize_keys
    ["expected attributes: #{display_sorted_hash(expected_attributes.except(*ignored_attributes))}",
     "actual attributes:   #{display_sorted_hash(actual_attributes.except(*ignored_attributes))}"]
      .join($/)
  end

  def get_normalized_attributes(journal)
    result = journal.attributes.symbolize_keys
    if result[:created_at]
      # µs are not stored in all DBMS
      result[:created_at] = result[:created_at].change(usec: 0)
    end

    result
  end

  def display_sorted_hash(hash)
    '{ ' + hash.sort.map { |k, v| "#{k.inspect}=>#{v.inspect}" }.join(', ') + ' }'
  end
end

describe Journal::AggregatedJournal, type: :model do
  let(:work_package) {
    FactoryGirl.build(:work_package)
  }
  let(:user1) { FactoryGirl.create(:user) }
  let(:user2) { FactoryGirl.create(:user) }
  let(:initial_author) { user1 }

  subject { described_class.aggregated_journals.sort_by &:id }

  before do
    allow(User).to receive(:current).and_return(initial_author)
    work_package.save!
  end

  it 'returns the one and only journal' do
    expect(subject.count).to eql 1
    expect(subject.first).to be_equivalent_to_journal work_package.journals.first
  end

  it 'also indicates its ID via notes_id' do
    expect(subject.first.notes_id).to eql work_package.journals.first.id
  end

  it 'is the initial journal' do
    expect(subject.first.initial?).to be_truthy
  end

  context 'WP updated immediately after uncommented change' do
    let(:notes) { nil }

    before do
      changes = { status: FactoryGirl.build(:status) }
      changes[:notes] = notes if notes

      expect(work_package.update_by!(new_author, changes)).to be_truthy
    end

    context 'by author of last change' do
      let(:new_author) { initial_author }

      it 'returns a single aggregated journal' do
        expect(subject.count).to eql 1
        expect(subject.first).to be_equivalent_to_journal work_package.journals.second
      end

      it 'is the initial journal' do
        expect(subject.first.initial?).to be_truthy
      end

      context 'with a comment' do
        let(:notes) { 'This is why I changed it.' }

        it 'returns a single aggregated journal' do
          expect(subject.count).to eql 1
          expect(subject.first).to be_equivalent_to_journal work_package.journals.second
        end

        context 'adding a second comment' do
          let(:notes) { 'Another comment, unrelated to the first one.' }

          before do
            expect(work_package.update_by!(new_author, notes: notes)).to be_truthy
          end

          it 'returns two journals' do
            expect(subject.count).to eql 2
            expect(subject.first).to be_equivalent_to_journal work_package.journals.second
            expect(subject.second).to be_equivalent_to_journal work_package.journals.last
          end

          it 'has one initial journal and one non-initial journal' do
            expect(subject.first.initial?).to be_truthy
            expect(subject.second.initial?).to be_falsey
          end
        end

        context 'adding another change without comment' do
          before do
            work_package.reload # need to update the lock_version, avoiding StaleObjectError
            expect(work_package.update_by!(new_author, subject: 'foo')).to be_truthy
          end

          it 'returns a single journal' do
            expect(subject.count).to eql 1
          end

          it 'combines the notes of the earlier journal with attributes of the later journal' do
            expected_journal = work_package.journals.last
            expected_journal.notes = work_package.journals.second.notes

            expect(subject.first).to be_equivalent_to_journal expected_journal
          end

          it 'indicates the ID of the earlier journal via notes_id' do
            expect(subject.first.notes_id).to eql work_package.journals.second.id
          end
        end
      end
    end

    context 'by a different author' do
      let(:new_author) { user2 }

      it 'returns both journals' do
        expect(subject.count).to eql 2
        expect(subject.first).to be_equivalent_to_journal work_package.journals.first
        expect(subject.second).to be_equivalent_to_journal work_package.journals.second
      end
    end
  end

  context 'WP updated after aggregation timeout expired' do
    let(:delay) { (Setting.journal_aggregation_time_minutes.to_i + 1).minutes }

    before do
      work_package.status = FactoryGirl.build(:status)
      work_package.save!
      work_package.journals.second.created_at += delay
      work_package.journals.second.save!
    end

    it 'returns both journals' do
      expect(subject.count).to eql 2
      expect(subject.first).to be_equivalent_to_journal work_package.journals.first
      expect(subject.second).to be_equivalent_to_journal work_package.journals.second
    end
  end

  context 'different WP updated immediately after change' do
    let(:other_wp) { FactoryGirl.build(:work_package) }
    before do
      other_wp.save!
    end

    it 'returns both journals' do
      expect(subject.count).to eql 2
      expect(subject.first).to be_equivalent_to_journal work_package.journals.first
      expect(subject.second).to be_equivalent_to_journal other_wp.journals.first
    end
  end

  context 'passing a journable as parameter' do
    subject { described_class.aggregated_journals(journable: work_package).sort_by &:id }
    let(:other_wp) { FactoryGirl.build(:work_package) }
    before do
      other_wp.save!
    end

    it 'only returns the journal for the requested work package' do
      expect(subject.count).to eq 1
      expect(subject.first).to be_equivalent_to_journal work_package.journals.first
    end
  end
end
